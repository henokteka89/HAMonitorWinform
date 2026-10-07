#Requires -Version 5.1
<#
.SYNOPSIS
    Single-file edition: everything (UI + engine) is in this one script. Optional thresholds file: SqlHAMonitor.config.json next to it.

    SQL Server HA Monitor - Availability Groups, Log Shipping and Replication status in one window.

.DESCRIPTION
    Read-only WinForms dashboard. Connects to one or more SQL Server instances, detects which HA roles each
    one plays (AG primary/secondary, log shipping primary/secondary/monitor, replication publisher/
    distributor/subscriber), shows current status, and explains any problem in plain language with
    troubleshooting steps, suggested T-SQL (shown only - never executed) and Microsoft Learn links.

    When a server can only see part of the picture (e.g. an AG secondary, a log shipping primary, a
    replication publisher with a remote distributor) the issue list offers a "Connect to <server>" button.

.PARAMETER Feature
    All (default) or a single feature: AG, LogShipping, Replication - runs a smaller, dedicated monitor.

.PARAMETER Server
    One or more servers to start with (Windows authentication). More can be added in the UI.

.PARAMETER RefreshSeconds
    Initial auto-refresh interval: 0 (off), 10, 30, 60 or 300. Changeable in the toolbar.

.EXAMPLE
    .\Start-SqlHAMonitor.ps1
.EXAMPLE
    .\Start-SqlHAMonitor.ps1 -Feature AG -Server SQL01 -RefreshSeconds 10

Unblock-File C:\Users\xx\Downloads\SqlHAMonitor.ps1
& C:\Users\xx\Downloads\SqlHAMonitor.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'AG', 'LogShipping', 'Replication')][string]$Feature = 'All',
    [string[]]$Server = @(),
    [ValidateSet(0, 10, 30, 60, 300)][int]$RefreshSeconds = 30,
    [string]$ConfigPath = ''
)

# Folder of this script. Empty when the code is pasted into a console instead of run as a file - fall back to the current folder.
$script:HAHome = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:HAHome 'SqlHAMonitor.config.json' }

# ---------- WinForms needs an STA thread ----------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if (-not $PSCommandPath) { Write-Warning 'This window is not in STA mode. Save the script as a .ps1 file and run it, or start PowerShell with -STA and paste again.'; return }
    $exe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Feature', $Feature, '-RefreshSeconds', $RefreshSeconds, '-ConfigPath', "`"$ConfigPath`"")
    if ($Server.Count) { $argList += @('-Server', ($Server -join ',')) }
    Start-Process -FilePath $exe -ArgumentList $argList
    return
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# Errors inside button/timer handlers go to the status bar instead of the WinForms crash dialog
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
[System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        try { $stMain.Text = "Error: $($e.Exception.Message)" } catch { }
    })
# The .cmd launchers hide the console, so show start-up failures in a message box
trap {
    [void][System.Windows.Forms.MessageBox]::Show("SqlHAMonitor stopped with an error:`r`n`r`n$($_.Exception.Message)`r`n`r`n$($_.InvocationInfo.PositionMessage)", 'SqlHAMonitor', 'OK', 'Error')
    break
}

#region ================= ENGINE (collection + analysis, read-only) =================
# Kept as text so the same code can be loaded both here (UI thread) and inside the background
# runspaces that run the checks. It is loaded as an in-memory module - nothing is written to disk.
$script:HAEngineCode = @'
Set-StrictMode -Version 2.0

# ======================= SqlHAMonitor.Core =======================
<#
    SqlHAMonitor.Core
    ------------------
    Shared plumbing for the HA monitor:
      * read-only SQL execution (with a guard that refuses anything that is not a SELECT-style batch)
      * the "issue" model (severity, plain-English explanation, steps, suggested queries, links, redirect)
      * server information, SQL Agent and job status helpers
      * the per-server orchestration (Invoke-HAServerCheck) used by the UI

    NOTHING in this module changes the server. Suggested fix queries are only text shown to the user.
#>


#region ---------- constants / links ----------

$script:SeverityRank = @{ 'OK' = 0; 'Info' = 1; 'Warning' = 2; 'Critical' = 3 }

# Microsoft Learn links used across features (verified Oct 2026)
$script:HALinks = @{
    AgTroubleshootIndex   = 'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/availability-groups/troubleshooting-alwayson-issues'
    AgConfigTroubleshoot  = 'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/troubleshoot-always-on-availability-groups-configuration-sql-server'
    AgFailover            = 'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/availability-groups/troubleshooting-availability-group-failover'
    AgPerformance         = 'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/monitor-performance-for-always-on-availability-groups'
    AgResume              = 'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/resume-an-availability-database-sql-server'
    AgJoinDb              = 'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/join-a-secondary-database-to-an-availability-group-sql-server'
    AgLease               = 'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/availability-group-lease-healthcheck-timeout'
    AgDiag                = 'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/availability-groups/use-agdiag-diagnose-availability-group-health-events'
    AgListener            = 'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/create-or-configure-an-availability-group-listener-sql-server'
    AgResolving           = 'https://learn.microsoft.com/en-us/archive/blogs/alwaysonpro/diagnose-unexpected-failover-or-availability-group-in-resolving-state'
    WsfcQuorum            = 'https://learn.microsoft.com/en-us/sql/sql-server/failover-clusters/windows/wsfc-quorum-modes-and-voting-configuration-sql-server'
    LsMonitorTsql         = 'https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/monitor-log-shipping-transact-sql'
    LsTables              = 'https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/log-shipping-tables-and-stored-procedures'
    LsReport              = 'https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/view-the-log-shipping-report-sql-server-management-studio'
    LsConfigure           = 'https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/configure-log-shipping-sql-server'
    LsErrorDetail         = 'https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/log-shipping-monitor-error-detail-transact-sql'
    ReplTroubleshoot      = 'https://learn.microsoft.com/en-us/sql/relational-databases/replication/troubleshoot-tran-repl-errors'
    ReplLatency           = 'https://learn.microsoft.com/en-us/sql/relational-databases/replication/monitor/measure-latency-and-validate-connections-for-transactional-replication'
    ReplReinit            = 'https://learn.microsoft.com/en-us/sql/relational-databases/replication/reinitialize-a-subscription'
    ReplBrowseCmds        = 'https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-browsereplcmds-transact-sql'
    ReplAgentAdmin        = 'https://learn.microsoft.com/en-us/sql/relational-databases/replication/agents/replication-agent-administration'
}

function Get-HALink {
    param([Parameter(Mandatory)][string]$Key, [string]$Title)
    $url = $script:HALinks[$Key]
    if (-not $url) { return $null }
    if (-not $Title) { $Title = $Key }
    [pscustomobject]@{ Title = $Title; Url = $url }
}

function Get-HADefaultThresholds {
    [pscustomobject]@{
        # Availability Groups
        AgLogSendQueueWarnMB    = 100
        AgLogSendQueueCritMB    = 1024
        AgRedoQueueWarnMB       = 100
        AgRedoQueueCritMB       = 1024
        AgLagWarnSeconds        = 60
        AgLagCritSeconds        = 300
        # Log shipping (used only when the configured threshold is missing)
        LsDefaultBackupThresholdMin  = 60
        LsDefaultRestoreThresholdMin = 45
        LsErrorLookbackHours         = 2
        # Replication
        ReplPendingCmdsWarn     = 10000
        ReplPendingCmdsCrit     = 100000
        ReplLatencyWarnSeconds  = 60
        ReplLatencyCritSeconds  = 300
        ReplAgentStaleMinutes   = 30
        ReplSubscriberStaleMin  = 60
        ReplErrorLookbackHours  = 2
        ReplLogUsedWarnPct      = 70
        ReplLogUsedCritPct      = 90
        # General
        QueryTimeoutSeconds     = 30
    }
}

function Import-HAThresholds {
    <# Merges config.json (if present) over the defaults. Unknown keys are ignored. #>
    param([string]$Path)
    $t = Get-HADefaultThresholds
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if ($cfg.PSObject.Properties['Thresholds']) { $cfg = $cfg.Thresholds }
            foreach ($p in $cfg.PSObject.Properties) {
                if ($t.PSObject.Properties[$p.Name]) { $t.($p.Name) = $p.Value }
            }
        } catch {
            Write-Warning "Could not read thresholds from $Path : $($_.Exception.Message). Using defaults."
        }
    }
    $t
}

#endregion

#region ---------- small helpers ----------

function ConvertTo-HASqlIdentifier {
    <# [name] with ] escaped - for building SUGGESTED queries and for db-scoped collection queries. #>
    param([AllowNull()][string]$Name)
    if ($null -eq $Name) { return '[?]' }
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-HASqlLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 'NULL' }
    "N'" + $Value.Replace("'", "''") + "'"
}

function Get-HAValue {
    <# Safe property read: returns $Default when the property is missing or DBNull/null. #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    $v = $p.Value
    if ($null -eq $v -or $v -is [System.DBNull]) { return $Default }
    $v
}

function Test-HATrue {
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $false }
    if ($Value -is [bool]) { return $Value }
    try { return ([int]$Value) -ne 0 } catch { return [bool]$Value }
}

function Format-HAMinutes {
    param($Minutes)
    if ($null -eq $Minutes) { return 'never' }
    $m = [double]$Minutes
    if ($m -lt 1)    { return 'less than a minute' }
    if ($m -lt 120)  { return ('{0:N0} min' -f $m) }
    if ($m -lt 2880) { return ('{0:N1} hours' -f ($m / 60)) }
    return ('{0:N1} days' -f ($m / 1440))
}

function Get-HASeverityRank { param([string]$Severity) $r = $script:SeverityRank[$Severity]; if ($null -eq $r) { 0 } else { $r } }

function Get-HAWorstSeverity {
    param([object[]]$Issues)
    $worst = 'OK'
    foreach ($i in @($Issues)) {
        if ($null -eq $i) { continue }
        if ((Get-HASeverityRank $i.Severity) -gt (Get-HASeverityRank $worst)) { $worst = $i.Severity }
    }
    $worst
}

#endregion

#region ---------- issue model ----------

function New-HAQuerySuggestion {
    <#
        A query shown to the user. Kind = Verify (safe, read-only check) or Fix (changes something - review first).
        RunOn tells the user WHERE to run it (e.g. "Primary: SQL01", "Distributor: SQL05 (distribution db)").
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Sql,
        [string]$RunOn = 'This server',
        [ValidateSet('Verify', 'Fix')][string]$Kind = 'Verify'
    )
    [pscustomobject]@{ Title = $Title; RunOn = $RunOn; Kind = $Kind; Sql = $Sql.Trim() }
}

function New-HAIssue {
    param(
        [Parameter(Mandatory)][ValidateSet('Critical', 'Warning', 'Info')][string]$Severity,
        [Parameter(Mandatory)][ValidateSet('AG', 'LS', 'REPL', 'SERVER')][string]$Feature,
        [string]$Server,
        [string]$Object,
        [Parameter(Mandatory)][string]$Title,
        [string]$Explanation,
        [string]$Impact,
        [string[]]$Steps = @(),
        [object[]]$Queries = @(),
        [object[]]$Links = @(),
        [string]$ConnectTo,
        [string]$ConnectReason
    )
    [pscustomobject]@{
        PSTypeName    = 'SqlHAMonitor.Issue'
        Severity      = $Severity
        Feature       = $Feature
        Server        = $Server
        Object        = $Object
        Title         = $Title
        Explanation   = $Explanation
        Impact        = $Impact
        Steps         = @($Steps | Where-Object { $_ })
        Queries       = @($Queries | Where-Object { $_ })
        Links         = @($Links | Where-Object { $_ })
        ConnectTo     = $ConnectTo
        ConnectReason = $ConnectReason
    }
}

function New-HAFeatureResult {
    param([Parameter(Mandatory)][string]$Feature)
    [pscustomobject]@{
        Feature    = $Feature
        Configured = $false
        Summary    = ''
        Roles      = ([System.Collections.Generic.List[string]]::new())
        Tables     = [ordered]@{}
        Issues     = ([System.Collections.Generic.List[object]]::new())
        Errors     = ([System.Collections.Generic.List[object]]::new())
    }
}

function ConvertTo-HAIssueText {
    <# Plain-text rendering of an issue (used for "copy issue" and tests). #>
    param([Parameter(Mandatory)]$Issue)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("[$($Issue.Severity)] $($Issue.Title)")
    if ($Issue.Server) { [void]$sb.AppendLine("Server : $($Issue.Server)") }
    if ($Issue.Object) { [void]$sb.AppendLine("Object : $($Issue.Object)") }
    [void]$sb.AppendLine()
    if ($Issue.Explanation) { [void]$sb.AppendLine('What is going on:'); [void]$sb.AppendLine($Issue.Explanation); [void]$sb.AppendLine() }
    if ($Issue.Impact) { [void]$sb.AppendLine('Why it matters:'); [void]$sb.AppendLine($Issue.Impact); [void]$sb.AppendLine() }
    if ($Issue.ConnectTo) { [void]$sb.AppendLine("Suggested connection: $($Issue.ConnectTo) - $($Issue.ConnectReason)"); [void]$sb.AppendLine() }
    if (@($Issue.Steps).Count) {
        [void]$sb.AppendLine('Steps to troubleshoot / resolve:')
        $n = 1; foreach ($s in $Issue.Steps) { [void]$sb.AppendLine("  $n. $s"); $n++ }
        [void]$sb.AppendLine()
    }
    foreach ($q in @($Issue.Queries)) {
        $tag = if ($q.Kind -eq 'Fix') { 'FIX - review before running' } else { 'VERIFY - read-only' }
        [void]$sb.AppendLine("-- $($q.Title)  [$tag]  Run on: $($q.RunOn)")
        [void]$sb.AppendLine($q.Sql)
        [void]$sb.AppendLine()
    }
    if (@($Issue.Links).Count) {
        [void]$sb.AppendLine('Further reading:')
        foreach ($l in $Issue.Links) { [void]$sb.AppendLine("  $($l.Title): $($l.Url)") }
    }
    $sb.ToString()
}

#endregion

#region ---------- read-only SQL execution ----------

function Test-HAReadOnlySql {
    <#
        Defence in depth: the collectors only issue SELECTs, but every batch is checked before it is sent.
        Comments, string literals and [bracketed identifiers] are removed first so that names such as
        backup_finish_date or a literal 'RESTORE%' do not trip the check.
        Returns $true when the batch looks read-only.
    #>
    param([Parameter(Mandatory)][string]$Sql)
    $s = $Sql
    $s = [regex]::Replace($s, '/\*.*?\*/', ' ', 'Singleline')
    $s = [regex]::Replace($s, '--[^\r\n]*', ' ')
    $s = [regex]::Replace($s, "N?'(?:[^']|'')*'", "''")
    $s = [regex]::Replace($s, '\[[^\]]*\]', '[x]')
    $forbidden = '\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|EXEC|EXECUTE|GRANT|REVOKE|DENY|BACKUP|RESTORE|DBCC|SHUTDOWN|KILL|RECONFIGURE|WAITFOR|OPENROWSET|OPENQUERY|OPENDATASOURCE|BULK|INTO|USE|sp_\w+|xp_\w+)\b'
    -not [regex]::IsMatch($s, $forbidden, 'IgnoreCase')
}

function New-HAConnectionInfo {
    <#
        Describes how to reach a server. Password is kept as a SecureString and handed to SqlCredential,
        never placed in the connection string.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [ValidateSet('Windows', 'Sql')][string]$AuthMode = 'Windows',
        [string]$UserName,
        [System.Security.SecureString]$Password,
        [bool]$Encrypt = $false,
        [bool]$TrustServerCertificate = $true,
        [int]$ConnectTimeout = 10
    )
    if ($AuthMode -eq 'Sql' -and (-not $UserName -or -not $Password)) { throw 'SQL authentication needs a user name and password.' }
    [pscustomobject]@{
        PSTypeName             = 'SqlHAMonitor.ConnectionInfo'
        Server                 = $Server.Trim()
        AuthMode               = $AuthMode
        UserName               = $UserName
        Password               = $Password
        Encrypt                = $Encrypt
        TrustServerCertificate = $TrustServerCertificate
        ConnectTimeout         = $ConnectTimeout
    }
}

function Open-HAConnection {
    param([Parameter(Mandatory)]$ConnectionInfo, [string]$Database = 'master')
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $ConnectionInfo.Server
    $b['Initial Catalog'] = $Database
    $b['Application Name'] = 'SqlHAMonitor (read-only)'
    $b['Connect Timeout'] = [int]$ConnectionInfo.ConnectTimeout
    $b['Encrypt'] = [bool]$ConnectionInfo.Encrypt
    $b['TrustServerCertificate'] = [bool]$ConnectionInfo.TrustServerCertificate
    # Never let the client redirect us to a readable secondary - we want the replica we asked for.
    $b['ApplicationIntent'] = 'ReadWrite'
    if ($ConnectionInfo.AuthMode -eq 'Windows') { $b['Integrated Security'] = $true }

    $cn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    if ($ConnectionInfo.AuthMode -eq 'Sql') {
        $pwd = $ConnectionInfo.Password.Copy()
        $pwd.MakeReadOnly()
        $cn.Credential = New-Object System.Data.SqlClient.SqlCredential($ConnectionInfo.UserName, $pwd)
    }
    $cn.Open()
    $cn
}

function Get-HASqlErrorNumber {
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.Data.SqlClient.SqlException]) { return $e.Number }
        $e = $e.InnerException
    }
    $null
}

function Get-HAErrorMessage {
    <# The SQL Server message without PowerShell's "Exception calling ... with N argument(s)" wrapper. #>
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.Data.SqlClient.SqlException]) { return $e.Message }
        if ($null -eq $e.InnerException) { break }
        $e = $e.InnerException
    }
    $m = [string]$Exception.Message
    $m -replace '^Exception calling "\w+" with "\d+" argument\(s\): "(.*)"$', '$1'
}

function Invoke-HAQuery {
    <#
        Runs a read-only batch and returns a List[object] of PSCustomObjects (DBNull -> $null).
        Every batch runs with a short lock timeout and READ UNCOMMITTED so monitoring never waits
        behind (or holds) locks on a busy production server.
    #>
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$SqlConnection,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$Timeout = 30
    )
    if (-not (Test-HAReadOnlySql -Sql $Query)) {
        throw "Refused to run a statement that is not read-only. (SqlHAMonitor only runs SELECT queries.)"
    }
    $cmd = $SqlConnection.CreateCommand()
    $cmd.CommandText = "SET NOCOUNT ON; SET LOCK_TIMEOUT 5000; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;`r`n" + $Query
    $cmd.CommandTimeout = $Timeout
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]; if ($null -eq $v) { $v = [System.DBNull]::Value }
        [void]$cmd.Parameters.AddWithValue($k, $v)
    }
    $dt = New-Object System.Data.DataTable
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    try { [void]$da.Fill($dt) } finally { $da.Dispose(); $cmd.Dispose() }

    $list = ([System.Collections.Generic.List[object]]::new())
    $cols = @($dt.Columns | ForEach-Object { $_.ColumnName })
    foreach ($row in $dt.Rows) {
        $h = [ordered]@{}
        foreach ($c in $cols) { $v = $row[$c]; if ($v -is [System.DBNull]) { $v = $null }; $h[$c] = $v }
        $list.Add([pscustomobject]$h)
    }
    , $list.ToArray()
}

function Invoke-HACollect {
    <#
        Collector wrapper: runs the query, and on failure records the error on the feature result
        instead of throwing, so one missing permission does not hide everything else.
    #>
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$SqlConnection,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [int]$Timeout = 30,
        [switch]$Optional
    )
    try {
        $rows = Invoke-HAQuery -SqlConnection $SqlConnection -Query $Query -Parameters $Parameters -Timeout $Timeout
        , $rows
    } catch {
        $Result.Errors.Add([pscustomobject]@{
                Label    = $Label
                Message  = (Get-HAErrorMessage $_.Exception)
                Number   = (Get-HASqlErrorNumber $_.Exception)
                Optional = [bool]$Optional
            })
        , @()
    }
}

function Add-HACollectErrorIssues {
    <# Turns collection errors into understandable issues (mostly permissions). #>
    param([Parameter(Mandatory)]$Result, [string]$Server)
    $permNumbers = @(229, 230, 262, 297, 300, 916, 15247)
    foreach ($e in $Result.Errors) {
        if ($e.Optional) { continue }
        if ($permNumbers -contains $e.Number) {
            $Result.Issues.Add((New-HAIssue -Severity Warning -Feature $Result.Feature -Server $Server -Object $e.Label `
                        -Title "Not enough permission to read: $($e.Label)" `
                        -Explanation "The login used by this monitor is not allowed to read some of the system information needed for this check, so this part of the picture is missing. Error: $($e.Message)" `
                        -Impact 'The status shown may be incomplete. Problems in this area would not be detected.' `
                        -Steps @(
                            'Ask the DBA team to grant the monitoring login read-only monitoring permissions (below).',
                            'VIEW SERVER STATE is needed for the DMVs; msdb read access is needed for SQL Agent and log shipping; the replmonitor role is needed on the distribution database for replication.'
                        ) `
                        -Queries @(
                            (New-HAQuerySuggestion -Kind Fix -RunOn 'This server' -Title 'Typical read-only monitoring permissions (adjust login name)' -Sql @"
-- Server-level DMV access (AG health, perf counters)
GRANT VIEW SERVER STATE TO [DOMAIN\MonitorLogin];
GRANT VIEW ANY DEFINITION TO [DOMAIN\MonitorLogin];
-- msdb: SQL Agent jobs + log shipping tables
USE msdb;
CREATE USER [DOMAIN\MonitorLogin] FOR LOGIN [DOMAIN\MonitorLogin];
ALTER ROLE SQLAgentReaderRole ADD MEMBER [DOMAIN\MonitorLogin];
ALTER ROLE db_datareader     ADD MEMBER [DOMAIN\MonitorLogin];
-- Distributor only: replication monitoring
USE distribution;
CREATE USER [DOMAIN\MonitorLogin] FOR LOGIN [DOMAIN\MonitorLogin];
ALTER ROLE replmonitor ADD MEMBER [DOMAIN\MonitorLogin];
"@)
                        )))
        } else {
            $Result.Issues.Add((New-HAIssue -Severity Warning -Feature $Result.Feature -Server $Server -Object $e.Label `
                        -Title "Could not read: $($e.Label)" `
                        -Explanation "The monitor could not run one of its read-only checks. Error $($e.Number): $($e.Message)" `
                        -Impact 'This part of the status is missing from the screen until the next successful refresh.' `
                        -Steps @('If this repeats, check the server is responsive and the error text above.', 'A lock timeout (error 1222) means the system table was busy; it usually clears on the next refresh.')))
        }
    }
}

#endregion

#region ---------- server info & SQL Agent ----------

function Get-HAServerInfo {
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$SqlConnection)
    $rows = Invoke-HAQuery -SqlConnection $SqlConnection -Query @"
SELECT  @@SERVERNAME                                              AS server_name,
        CAST(SERVERPROPERTY('MachineName') AS nvarchar(128))      AS machine_name,
        CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))   AS product_version,
        CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128))     AS product_level,
        CAST(SERVERPROPERTY('Edition') AS nvarchar(128))          AS edition,
        CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int)  AS is_hadr_enabled,
        CAST(SERVERPROPERTY('EngineEdition') AS int)              AS engine_edition,
        IS_SRVROLEMEMBER('sysadmin')                              AS is_sysadmin,
        HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')        AS has_view_server_state,
        SUSER_SNAME()                                             AS login_name,
        SYSDATETIME()                                             AS server_time
"@
    $info = $rows[0]
    $major = 0
    try { $major = [int](($info.product_version -split '\.')[0]) } catch { }
    $info | Add-Member -NotePropertyName major_version -NotePropertyValue $major

    # SQL Agent state (dm_server_services needs VIEW SERVER STATE; fall back to the Agent session)
    $agent = 'Unknown'
    try {
        $a = Invoke-HAQuery -SqlConnection $SqlConnection -Query @"
SELECT TOP (1) status_desc FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%'
"@
        if ($a.Count -gt 0 -and $a[0].status_desc) { $agent = [string]$a[0].status_desc }
    } catch { }
    if ($agent -eq 'Unknown') {
        try {
            $a = Invoke-HAQuery -SqlConnection $SqlConnection -Query @"
SELECT COUNT(*) AS n FROM sys.dm_exec_sessions WHERE program_name = N'SQLAgent - Generic Refresher'
"@
            if ($a.Count -gt 0) { if ([int]$a[0].n -gt 0) { $agent = 'Running' } else { $agent = 'Stopped' } }
        } catch { }
    }
    $info | Add-Member -NotePropertyName agent_status -NotePropertyValue $agent
    $info
}

function Get-HAJobStatus {
    <#
        Latest outcome of SQL Agent jobs, by job_id list and/or a job category LIKE pattern.
        run_status: 0 Failed, 1 Succeeded, 2 Retry, 3 Canceled, 4 In progress
        Times are server-local (that is how Agent stores them); minutes_since_last_run is computed on the server.
    #>
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$SqlConnection,
        [string[]]$JobIds = @(),
        [string]$CategoryLike
    )
    $ids = @()
    foreach ($j in $JobIds) { if ($j) { $g = [guid]::Empty; if ([guid]::TryParse([string]$j, [ref]$g)) { $ids += "'$g'" } } }
    $where = @()
    if ($ids.Count) { $where += "j.job_id IN (" + (($ids | Select-Object -Unique) -join ',') + ")" }
    $params = @{}
    if ($CategoryLike) { $where += 'c.name LIKE @cat'; $params['@cat'] = $CategoryLike }
    if (-not $where.Count) { return , @() }

    $q = @"
SELECT  j.job_id, j.name AS job_name, j.enabled, c.name AS category,
        lr.run_status, lr.run_datetime, lr.message AS last_message,
        DATEDIFF(MINUTE, lr.run_datetime, GETDATE()) AS minutes_since_last_run,
        CASE WHEN ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL THEN 1 ELSE 0 END AS is_running
FROM    msdb.dbo.sysjobs j
JOIN    msdb.dbo.syscategories c ON c.category_id = j.category_id
OUTER APPLY (SELECT TOP (1) h.run_status, h.message,
                    CAST(CAST(h.run_date AS char(8)) + ' ' +
                         STUFF(STUFF(RIGHT('000000' + CAST(h.run_time AS varchar(6)), 6), 5, 0, ':'), 3, 0, ':') AS datetime) AS run_datetime
             FROM msdb.dbo.sysjobhistory h
             WHERE h.job_id = j.job_id AND h.step_id = 0
             ORDER BY h.instance_id DESC) lr
OUTER APPLY (SELECT TOP (1) a.start_execution_date, a.stop_execution_date
             FROM msdb.dbo.sysjobactivity a
             WHERE a.job_id = j.job_id AND a.session_id = (SELECT MAX(s.session_id) FROM msdb.dbo.syssessions s)
             ORDER BY a.start_execution_date DESC) ja
WHERE   $($where -join ' OR ')
"@
    Invoke-HAQuery -SqlConnection $SqlConnection -Query $q -Parameters $params
}

function Get-HAJobOutcomeText {
    param($Job)
    if ($null -eq $Job) { return 'job not found' }
    if (Test-HATrue $Job.is_running) { return 'running now' }
    switch ([string]$Job.run_status) {
        '0' { 'FAILED' }
        '1' { 'succeeded' }
        '2' { 'retrying' }
        '3' { 'canceled' }
        '4' { 'in progress' }
        default { 'no history yet' }
    }
}

function New-HAJobIssue {
    <# Standard issue for a disabled / failed SQL Agent job that a feature depends on. #>
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Feature,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Purpose,   # e.g. "log shipping backup job for SalesDB"
        [string]$WhatItDoes,
        [object[]]$Links = @()
    )
    $name = [string]$Job.job_name
    $lit = ConvertTo-HASqlLiteral $name
    $verify = New-HAQuerySuggestion -Title 'Recent history of this job (newest first)' -RunOn $Server -Sql @"
SELECT TOP (20) h.run_date, h.run_time, h.step_id, h.step_name,
       CASE h.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 2 THEN 'Retry'
                         WHEN 3 THEN 'Canceled' WHEN 4 THEN 'In progress' END AS outcome,
       h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = $lit
ORDER BY h.instance_id DESC;
"@
    if (-not (Test-HATrue $Job.enabled)) {
        return New-HAIssue -Severity Critical -Feature $Feature -Server $Server -Object $name `
            -Title "SQL Agent job is DISABLED: $name" `
            -Explanation "The $Purpose is switched off, so it will not run on its schedule. $WhatItDoes" `
            -Impact 'Nothing moves forward until the job is enabled again. Someone may have disabled it on purpose (maintenance) - check before enabling.' `
            -Steps @('Confirm with the team whether the job was disabled intentionally (patching, maintenance, migration).', 'If not intentional, enable the job and watch the next run.') `
            -Queries @($verify, (New-HAQuerySuggestion -Kind Fix -RunOn $Server -Title 'Enable the job' -Sql "EXEC msdb.dbo.sp_update_job @job_name = $lit, @enabled = 1;")) `
            -Links $Links
    }
    if ([string]$Job.run_status -eq '0') {
        $msg = [string]$Job.last_message
        if ($msg.Length -gt 600) { $msg = $msg.Substring(0, 600) + '...' }
        return New-HAIssue -Severity Critical -Feature $Feature -Server $Server -Object $name `
            -Title "Last run FAILED: $name" `
            -Explanation "The $Purpose failed the last time it ran ($($Job.run_datetime)). $WhatItDoes`r`nAgent message: $msg" `
            -Impact 'Until the job succeeds again this step of the data flow is stuck.' `
            -Steps @('Open the job history (query below) and read the message of the failing step - it usually names the real cause (access denied, file not found, login failed...).', 'Fix the cause, then start the job manually and confirm it succeeds.') `
            -Queries @($verify, (New-HAQuerySuggestion -Kind Fix -RunOn $Server -Title 'Start the job once the cause is fixed' -Sql "EXEC msdb.dbo.sp_start_job @job_name = $lit;")) `
            -Links $Links
    }
    $null
}

function New-HAAgentStoppedIssue {
    param([string]$Server, [string]$Feature, [string]$Why)
    New-HAIssue -Severity Critical -Feature $Feature -Server $Server -Object 'SQL Server Agent' `
        -Title 'SQL Server Agent is not running' `
        -Explanation "SQL Server Agent is the scheduler that runs the jobs this feature depends on. $Why" `
        -Impact 'All scheduled HA jobs on this server are stopped until Agent is started.' `
        -Steps @('Start the "SQL Server Agent" service from SQL Server Configuration Manager (preferred) or services.msc.', 'If it stops again, check the Agent error log (SQLAGENT.OUT) in the instance LOG folder.') `
        -Queries @((New-HAQuerySuggestion -RunOn $Server -Title 'Confirm Agent service state' -Sql "SELECT servicename, status_desc, startup_type_desc, service_account FROM sys.dm_server_services;"))
}

#endregion

#region ---------- orchestration ----------

function Invoke-HAServerCheck {
    <#
        Connects once, collects server info, then runs the requested feature reports.
        Called on a background runspace by the UI. Never throws: connection problems become an issue.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [string[]]$Features = @('AG', 'LS', 'REPL'),
        $Thresholds
    )
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = [pscustomobject]@{
        Server      = $Connection.Server
        ServerName  = $Connection.Server
        Connected   = $false
        Info        = $null
        Error       = $null
        Features    = [ordered]@{}
        Roles       = ([System.Collections.Generic.List[string]]::new())
        Issues      = ([System.Collections.Generic.List[object]]::new())
        Status      = 'OK'
        CheckedAt   = Get-Date
        DurationMs  = 0
    }
    $cn = $null
    try {
        $cn = Open-HAConnection -ConnectionInfo $Connection
        $res.Connected = $true
        $info = Get-HAServerInfo -SqlConnection $cn
        $res.Info = $info
        $res.ServerName = [string]$info.server_name

        if (-not (Test-HATrue $info.has_view_server_state)) {
            $res.Issues.Add((New-HAIssue -Severity Warning -Feature SERVER -Server $res.ServerName -Object $info.login_name `
                        -Title 'Monitoring login lacks VIEW SERVER STATE' `
                        -Explanation 'Most health information (AG state, queues, performance counters) comes from views that need the VIEW SERVER STATE permission. Without it, the screens will be mostly empty.' `
                        -Impact 'Problems may go undetected.' `
                        -Steps @('Ask the DBA team to grant VIEW SERVER STATE to the monitoring login.') `
                        -Queries @((New-HAQuerySuggestion -Kind Fix -RunOn $res.ServerName -Title 'Grant read-only DMV access' -Sql ("GRANT VIEW SERVER STATE TO " + (ConvertTo-HASqlIdentifier $info.login_name) + ";")))))
        }

        $map = @{ AG = 'Get-HAAgReport'; LS = 'Get-HALogShippingReport'; REPL = 'Get-HAReplicationReport' }
        foreach ($f in $Features) {
            $fn = $map[$f]
            if (-not $fn) { continue }
            try {
                $fr = & $fn -SqlConnection $cn -ServerInfo $info -Thresholds $Thresholds
            } catch {
                $fr = New-HAFeatureResult -Feature $f
                $fr.Summary = "Check failed: $($_.Exception.Message)"
                $fr.Issues.Add((New-HAIssue -Severity Warning -Feature $f -Server $res.ServerName -Title "The $f check failed to run" `
                            -Explanation "An unexpected error stopped this check: $($_.Exception.Message)" -Impact 'Status for this feature is unknown until the next successful refresh.'))
            }
            $res.Features[$f] = $fr
            foreach ($r in $fr.Roles) { if (-not $res.Roles.Contains($r)) { $res.Roles.Add($r) } }
            foreach ($i in $fr.Issues) { if (-not $i.Server) { $i.Server = $res.ServerName }; $res.Issues.Add($i) }
        }
    } catch {
        $res.Error = Get-HAErrorMessage $_.Exception
        $num = Get-HASqlErrorNumber $_.Exception
        $steps = @(
            'Check the server name / instance name and port are correct (e.g. SERVER\INSTANCE or SERVER,1433).',
            'Make sure the SQL Server service is running and reachable from this PC (ping, Test-NetConnection SERVER -Port 1433).',
            'If the login failed, check the account has access to this server.',
            'For "certificate chain not trusted" errors, tick "Trust server certificate" in the connection dialog.'
        )
        $res.Issues.Add((New-HAIssue -Severity Critical -Feature SERVER -Server $Connection.Server -Object $Connection.Server `
                    -Title 'Cannot connect to this server' `
                    -Explanation "The monitor could not open a connection$(if ($num) { " (error $num)" }): $($res.Error)" `
                    -Impact 'No status can be shown for this server. If this is a primary, applications may be affected too.' `
                    -Steps $steps))
    } finally {
        if ($cn) { $cn.Dispose() }
        $sw.Stop()
        $res.DurationMs = $sw.ElapsedMilliseconds
    }
    $res.Status = Get-HAWorstSeverity $res.Issues
    $res
}

#endregion

# ======================= SqlHAMonitor.AG =======================
<#
    SqlHAMonitor.AG - Always On Availability Groups
    -----------------------------------------------
    Works from any replica:
      * On the PRIMARY you get the full picture (all replicas, all databases, queues, lag).
      * On a SECONDARY SQL Server only exposes the local replica, so the monitor says which server is primary
        and offers to connect to it - but still checks the local things only a secondary can show
        (redo blocked by readers, connection to the primary, local redo queue).
    Supported: SQL Server 2012+ (columns added later are not required).
#>


function Get-HAAgData {
    <# Read-only collection. Returns a hashtable of row lists. #>
    param([Parameter(Mandatory)]$SqlConnection, [Parameter(Mandatory)]$Result, [int]$Timeout = 30)

    $d = @{}
    $d.Groups = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'Availability groups' -Query @"
SELECT  ag.group_id, ag.name AS ag_name, ag.failure_condition_level, ag.health_check_timeout,
        ags.primary_replica, ags.primary_recovery_health_desc,
        ags.synchronization_health_desc AS ag_sync_health
FROM    sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_group_states ags ON ags.group_id = ag.group_id
"@

    $d.Replicas = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'AG replicas' -Query @"
SELECT  ar.group_id, ar.replica_id, ar.replica_server_name, ar.endpoint_url,
        ar.availability_mode_desc, ar.failover_mode_desc, ar.secondary_role_allow_connections_desc,
        ar.session_timeout,
        ars.is_local, ars.role_desc, ars.operational_state_desc, ars.connected_state_desc,
        ars.recovery_health_desc, ars.synchronization_health_desc,
        ars.last_connect_error_number, ars.last_connect_error_description, ars.last_connect_error_timestamp
FROM    sys.availability_replicas ar
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
"@

    # cluster_states has a row per database per replica (even ones not joined); replica_states only for what this server can see
    $d.Databases = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'AG databases' -Query @"
SELECT  ar.group_id, dcs.replica_id, ar.replica_server_name, ar.availability_mode_desc, ar.failover_mode_desc,
        dcs.group_database_id, dcs.database_name, dcs.is_failover_ready, dcs.is_database_joined,
        drs.is_local, drs.synchronization_state_desc, drs.synchronization_health_desc, drs.database_state_desc,
        drs.is_suspended, drs.suspend_reason_desc,
        drs.log_send_queue_size, drs.log_send_rate, drs.redo_queue_size, drs.redo_rate,
        drs.last_sent_time, drs.last_received_time, drs.last_hardened_time, drs.last_redone_time, drs.last_commit_time
FROM    sys.dm_hadr_database_replica_cluster_states dcs
JOIN    sys.availability_replicas ar ON ar.replica_id = dcs.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs
       ON drs.replica_id = dcs.replica_id AND drs.group_database_id = dcs.group_database_id
"@

    $d.Listeners = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'AG listeners' -Optional -Query @"
SELECT  l.group_id, l.dns_name, l.port, ip.ip_address, ip.ip_subnet_mask, ip.state_desc AS ip_state
FROM    sys.availability_group_listeners l
LEFT JOIN sys.availability_group_listener_ip_addresses ip ON ip.listener_id = l.listener_id
"@

    $d.Cluster = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'WSFC cluster' -Optional -Query @"
SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster
"@
    $d.Members = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'WSFC members' -Optional -Query @"
SELECT member_name, member_type_desc, member_state_desc, number_of_quorum_votes FROM sys.dm_hadr_cluster_members
"@

    $d.Endpoints = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'HADR endpoint' -Query @"
SELECT  e.name, e.state_desc, e.role_desc, e.connection_auth_desc, e.encryption_algorithm_desc, t.port
FROM    sys.database_mirroring_endpoints e
LEFT JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id
"@

    # Only meaningful on a readable secondary: redo thread blocked by a reader
    $d.RedoBlocking = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $Timeout -Label 'Redo blocking' -Optional -Query @"
SELECT  r.session_id, DB_NAME(r.database_id) AS database_name, r.command, r.blocking_session_id,
        r.wait_type, r.wait_time, r.wait_resource
FROM    sys.dm_exec_requests r
WHERE   r.command IN (N'DB STARTUP', N'PARALLEL REDO TASK', N'PARALLEL REDO HELP TASK')
  AND   r.blocking_session_id <> 0
"@
    $d
}

function Get-HAAgIssues {
    <#
        Pure analysis (no SQL). $Data = output of Get-HAAgData (or test data).
        Returns a list of issues, root causes first: a disconnected replica produces ONE issue,
        not one per database.
    #>
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Server, $Thresholds)
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $issues = ([System.Collections.Generic.List[object]]::new())
    $T = $Thresholds

    $lnkIndex = Get-HALink AgTroubleshootIndex 'Microsoft: Troubleshooting Always On issues (index)'
    $lnkPerf = Get-HALink AgPerformance 'Microsoft: Monitor AG performance (queues, RPO/RTO)'
    $lnkCfg = Get-HALink AgConfigTroubleshoot 'Microsoft: Troubleshoot AG configuration (endpoints, permissions, firewall)'

    $groups = @($Data.Groups)
    $replicas = @($Data.Replicas)
    $dbs = @($Data.Databases)

    # ---------- instance-level: endpoint ----------
    if ($groups.Count -gt 0) {
        $eps = @($Data.Endpoints)
        if ($eps.Count -eq 0) {
            $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object 'HADR endpoint' `
                        -Title 'No database mirroring (HADR) endpoint on this server' `
                        -Explanation 'Replicas of an availability group talk to each other through a special network "door" called the HADR endpoint (usually port 5022). This server has none, so it cannot send or receive AG data.' `
                        -Impact 'Data cannot flow to or from this replica.' `
                        -Steps @('Create the endpoint (normally done by the AG wizard) and grant CONNECT on it to the service accounts of the other replicas.', 'Open the endpoint port in the firewall between replicas.') `
                        -Queries @((New-HAQuerySuggestion -Kind Fix -RunOn $Server -Title 'Create HADR endpoint (example - adjust port/account)' -Sql @"
CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [DOMAIN\SqlServiceAccountOfOtherReplica];
"@)) -Links @($lnkCfg)))
        } else {
            foreach ($e in $eps) {
                if ([string]$e.state_desc -ne 'STARTED') {
                    $ep = ConvertTo-HASqlIdentifier $e.name
                    $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object "Endpoint $($e.name)" `
                                -Title "HADR endpoint is $($e.state_desc)" `
                                -Explanation "The network endpoint the replicas use to talk to each other ($($e.name), port $($e.port)) is not started, so this replica is cut off from its partners." `
                                -Impact 'No AG data moves to or from this server while the endpoint is stopped.' `
                                -Steps @('Start the endpoint (query below).', 'Check the SQL Server error log for why it stopped (someone may have stopped it during maintenance).') `
                                -Queries @(
                                (New-HAQuerySuggestion -RunOn $Server -Title 'Endpoint state' -Sql 'SELECT e.name, e.state_desc, e.role_desc, t.port FROM sys.database_mirroring_endpoints e JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id;'),
                                (New-HAQuerySuggestion -Kind Fix -RunOn $Server -Title 'Start the endpoint' -Sql "ALTER ENDPOINT $ep STATE = STARTED;")
                            ) -Links @($lnkCfg)))
                }
            }
        }
    }

    # ---------- cluster ----------
    foreach ($c in @($Data.Cluster)) {
        $q = [string]$c.quorum_state_desc
        if ($q -and $q -ne 'NORMAL_QUORUM') {
            $sev = 'Critical'
            $issues.Add((New-HAIssue -Severity $sev -Feature AG -Server $Server -Object "Cluster $($c.cluster_name)" `
                        -Title "Windows cluster quorum is $q" `
                        -Explanation ("The Windows failover cluster underneath the AG decides which server is in charge by majority vote ('quorum'). " +
                            $(if ($q -eq 'FORCED_QUORUM') { 'Quorum was FORCED, meaning someone overrode the vote to bring the cluster up - this is an emergency/disaster-recovery state.' } else { 'Right now the cluster does not have a healthy majority.' })) `
                        -Impact 'Automatic failover may not work; if quorum is lost completely the AG goes offline for applications.' `
                        -Steps @('Check which cluster nodes / witness are down (query below or Failover Cluster Manager).', 'Bring nodes/witness back online. After a forced quorum, follow the DR runbook to return to normal quorum.') `
                        -Queries @((New-HAQuerySuggestion -RunOn $Server -Title 'Cluster members and votes' -Sql 'SELECT member_name, member_type_desc, member_state_desc, number_of_quorum_votes FROM sys.dm_hadr_cluster_members;')) `
                        -Links @((Get-HALink WsfcQuorum 'Microsoft: WSFC quorum modes and voting'), $lnkIndex)))
        }
    }
    foreach ($m in @($Data.Members)) {
        if ([string]$m.member_state_desc -eq 'DOWN') {
            $issues.Add((New-HAIssue -Severity Warning -Feature AG -Server $Server -Object "Cluster member $($m.member_name)" `
                        -Title "Cluster member is DOWN: $($m.member_name) ($($m.member_type_desc))" `
                        -Explanation 'One member of the Windows failover cluster (a server node or the witness) is not responding. The cluster still works while it has a majority, but there is less room for another failure.' `
                        -Impact "If another voting member fails, the cluster can lose quorum. Votes held by this member: $($m.number_of_quorum_votes)." `
                        -Steps @('Check the server / file-share / cloud witness is up and reachable.', 'Look in Failover Cluster Manager > Cluster Events for the reason.') `
                        -Links @((Get-HALink WsfcQuorum 'Microsoft: WSFC quorum modes and voting'))))
        }
    }

    foreach ($g in $groups) {
        $ag = [string]$g.ag_name
        $agReps = @($replicas | Where-Object { $_.group_id -eq $g.group_id })
        $local = @($agReps | Where-Object { Test-HATrue $_.is_local }) | Select-Object -First 1
        $localRole = [string](Get-HAValue $local 'role_desc' '')
        $primaryName = [string](Get-HAValue $g 'primary_replica' '')
        $agDbs = @($dbs | Where-Object { $_.group_id -eq $g.group_id })
        $agLit = ConvertTo-HASqlIdentifier $ag

        # --- role / redirect ---
        if ($localRole -eq 'SECONDARY') {
            $issues.Add((New-HAIssue -Severity Info -Feature AG -Server $Server -Object "AG $ag" `
                        -Title "Connected to a SECONDARY of $ag - primary is $primaryName" `
                        -Explanation "This server is a secondary copy in availability group '$ag'. SQL Server only shows the full health picture (all replicas, how far behind each one is) on the primary. This screen still shows what this secondary can see about itself." `
                        -Impact 'No problem by itself. For the complete view, connect to the primary.' `
                        -ConnectTo $primaryName -ConnectReason "Primary of $ag - shows every replica and database"))
        }
        if ($localRole -eq 'RESOLVING' -or ($local -and -not $primaryName)) {
            $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object "AG $ag" `
                        -Title "$ag has no primary right now (RESOLVING)" `
                        -Explanation 'The availability group is between owners: no server is currently acting as the primary. This happens during a failover, or when the Windows cluster lost quorum or a health check failed.' `
                        -Impact 'Applications using this AG cannot write (and usually cannot connect through the listener) until a primary is back.' `
                        -Steps @(
                            'Check the Windows cluster first: are nodes up, is quorum normal? (Failover Cluster Manager or the query below).',
                            'Look at the SQL Server error log and the cluster log on the previous primary around the time of the problem (lease timeout 19407, health check failures).',
                            'If a failover is in progress, wait a minute and refresh. If it stays RESOLVING, the DBA must bring the AG online on a suitable replica - do NOT force failover without understanding data-loss risk.'
                        ) `
                        -Queries @(
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Cluster quorum and members' -Sql "SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster;`r`nSELECT member_name, member_type_desc, member_state_desc FROM sys.dm_hadr_cluster_members;"),
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Replica roles as seen from here' -Sql "SELECT ar.replica_server_name, ars.role_desc, ars.operational_state_desc, ars.connected_state_desc`r`nFROM sys.availability_replicas ar JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id;")
                        ) `
                        -Links @((Get-HALink AgResolving 'Microsoft: Diagnose unexpected failover / RESOLVING state'), (Get-HALink AgFailover 'Microsoft: Troubleshoot AG failover'), (Get-HALink AgLease 'Microsoft: Lease and health-check timeouts'), (Get-HALink AgDiag 'Microsoft: AGDiag tool'))))
        }

        # --- local replica health ---
        if ($local) {
            $op = [string](Get-HAValue $local 'operational_state_desc' '')
            if ($op -and $op -ne 'ONLINE') {
                $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object "AG $ag / replica $($local.replica_server_name)" `
                            -Title "This replica's operational state is $op" `
                            -Explanation "The AG on this server is not fully running (state $op). States like PENDING or FAILED usually follow a cluster problem or a failed failover." `
                            -Impact 'This replica is not doing its job in the AG right now.' `
                            -Steps @('Check the SQL Server error log on this server.', 'Check the AG resource in Failover Cluster Manager.') -Links @($lnkIndex)))
            }
            if ($localRole -eq 'SECONDARY' -and [string](Get-HAValue $local 'connected_state_desc' '') -eq 'DISCONNECTED') {
                $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object "AG $ag / replica $($local.replica_server_name)" `
                            -Title "This secondary is DISCONNECTED from the primary ($primaryName)" `
                            -Explanation 'This copy cannot talk to the primary, so it is not receiving any changes and is falling behind.' `
                            -Impact 'Data on this secondary is getting older every minute. Failing over to it now would lose data.' `
                            -Steps @(
                                "Check network/firewall from this server to $primaryName on the endpoint port (Test-NetConnection $primaryName -Port 5022).",
                                'Check the HADR endpoint is STARTED on both servers and the service accounts have CONNECT permission on each other''s endpoint.',
                                'Read the last connection error (query below) and the SQL error log on both servers.'
                            ) `
                            -Queries @((New-HAQuerySuggestion -RunOn $Server -Title 'Last connection error' -Sql "SELECT ar.replica_server_name, ars.connected_state_desc, ars.last_connect_error_number, ars.last_connect_error_description, ars.last_connect_error_timestamp`r`nFROM sys.availability_replicas ar JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id;")) `
                            -Links @($lnkCfg) -ConnectTo $primaryName -ConnectReason 'See the connection from the primary side'))
            }
        }

        # --- replica-level problems (seen from primary) ---
        $badReplicas = @{}
        if ($localRole -eq 'PRIMARY') {
            foreach ($r in $agReps) {
                if (Test-HATrue $r.is_local) { continue }
                $rname = [string]$r.replica_server_name
                if ([string](Get-HAValue $r 'connected_state_desc' '') -eq 'DISCONNECTED') {
                    $badReplicas[[string]$r.replica_id] = $true
                    $err = Get-HAValue $r 'last_connect_error_description' ''
                    $errNo = Get-HAValue $r 'last_connect_error_number' ''
                    $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object "AG $ag / replica $rname" `
                                -Title "Secondary $rname is DISCONNECTED" `
                                -Explanation ("The primary cannot talk to the secondary $rname, so none of its databases are getting new changes. " +
                                    $(if ($err) { "Last connection error $($errNo): $err" } else { 'No connection error was recorded - the secondary SQL Server may be down or restarting.' })) `
                                -Impact "$rname is falling behind. If the primary failed now, failing over to $rname would lose data, and automatic failover to it is not possible." `
                                -Steps @(
                                    "Is SQL Server running on ${rname}? Can you connect to it?",
                                    "Check network/firewall between the servers on the endpoint port ($($r.endpoint_url)).",
                                    'On both servers: HADR endpoint STARTED, and each service account has CONNECT on the other''s endpoint.',
                                    "Check the SQL error log on $rname - connecting to it here shows its own view of the problem."
                                ) `
                                -Queries @(
                                    (New-HAQuerySuggestion -RunOn "Primary: $Server" -Title 'Replica connection state and last error' -Sql "SELECT ar.replica_server_name, ar.endpoint_url, ars.connected_state_desc, ars.last_connect_error_number, ars.last_connect_error_description, ars.last_connect_error_timestamp`r`nFROM sys.availability_replicas ar JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id;"),
                                    (New-HAQuerySuggestion -RunOn "Both replicas" -Title 'Endpoint state and who may connect' -Sql "SELECT e.name, e.state_desc, t.port, e.connection_auth_desc FROM sys.database_mirroring_endpoints e JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id;`r`nSELECT p.permission_name, p.state_desc, SUSER_NAME(p.grantee_principal_id) AS grantee`r`nFROM sys.server_permissions p WHERE p.class_desc = 'ENDPOINT';")
                                ) `
                                -Links @($lnkCfg, $lnkIndex) -ConnectTo $rname -ConnectReason 'See the secondary''s own view (its error, its endpoint)'))
                }
            }
        }

        # --- database-level ---
        $byDb = $agDbs | Group-Object database_name
        foreach ($grp in $byDb) {
            $dbName = [string]$grp.Name
            $dbLit = ConvertTo-HASqlIdentifier $dbName
            $rows = @($grp.Group)
            $pri = @($rows | Where-Object { [string]$_.replica_server_name -eq $primaryName }) | Select-Object -First 1

            foreach ($row in $rows) {
                $rname = [string]$row.replica_server_name
                $isPriRow = ($rname -eq $primaryName)
                $obj = "AG $ag / $dbName on $rname"

                # primary database itself
                if ($isPriRow) {
                    if ($null -eq (Get-HAValue $row 'synchronization_state_desc')) { continue }  # not visible from this server
                    if (Test-HATrue $row.is_suspended) {
                        $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object $obj `
                                    -Title "Data movement SUSPENDED on the primary for $dbName" `
                                    -Explanation "Copying of changes for $dbName was paused on the primary (reason: $($row.suspend_reason_desc)). While paused, no secondary receives new changes for this database." `
                                    -Impact 'All secondaries fall behind; the transaction log on the primary cannot be cleared and will keep growing.' `
                                    -Steps @('Find out why it was suspended (manual pause for maintenance, or an error - check the SQL error log).', 'Resume data movement once the cause is fixed and watch the send queue drain.') `
                                    -Queries @(
                                        (New-HAQuerySuggestion -RunOn "Primary: $primaryName" -Title 'Suspend state' -Sql "SELECT DB_NAME(database_id) AS db, is_suspended, suspend_reason_desc, synchronization_state_desc FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;"),
                                        (New-HAQuerySuggestion -Kind Fix -RunOn "Primary: $primaryName" -Title 'Resume data movement' -Sql "ALTER DATABASE $dbLit SET HADR RESUME;")
                                    ) -Links @((Get-HALink AgResume 'Microsoft: Resume an availability database'))))
                    }
                    $st = [string](Get-HAValue $row 'database_state_desc' '')
                    if ($st -and $st -ne 'ONLINE') {
                        $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object $obj `
                                    -Title "Primary database $dbName is $st" `
                                    -Explanation "The main (primary) copy of $dbName is not online (state $st)." `
                                    -Impact 'Applications cannot use this database.' `
                                    -Steps @('Check the SQL Server error log for the database.', 'States like RECOVERING usually clear on their own after a restart/failover; SUSPECT needs immediate DBA attention.') -Links @($lnkIndex)))
                    }
                    continue
                }

                if ($badReplicas.ContainsKey([string]$row.replica_id)) { continue }   # already explained by the replica issue

                if (-not (Test-HATrue (Get-HAValue $row 'is_database_joined' 1))) {
                    $issues.Add((New-HAIssue -Severity Warning -Feature AG -Server $Server -Object $obj `
                                -Title "$dbName is not joined to $ag on $rname" `
                                -Explanation "The database belongs to the AG, but the copy on $rname was never joined (or was removed). That server has no working copy of this database." `
                                -Impact "If the primary fails, $dbName will not be available on $rname." `
                                -Steps @(
                                    "On $rname, check whether the database exists in RESTORING state (restored WITH NORECOVERY).",
                                    'If it exists and is recent enough, join it (query below). If not, restore a recent full + log backup WITH NORECOVERY first, or use automatic seeding.'
                                ) `
                                -Queries @(
                                    (New-HAQuerySuggestion -RunOn "Secondary: $rname" -Title 'Is the database there and restoring?' -Sql "SELECT name, state_desc FROM sys.databases WHERE name = $(ConvertTo-HASqlLiteral $dbName);"),
                                    (New-HAQuerySuggestion -Kind Fix -RunOn "Secondary: $rname" -Title 'Join the database to the AG' -Sql "ALTER DATABASE $dbLit SET HADR AVAILABILITY GROUP = $agLit;")
                                ) -Links @((Get-HALink AgJoinDb 'Microsoft: Join a secondary database to an AG')) `
                                -ConnectTo $rname -ConnectReason 'The join has to be done on the secondary'))
                    continue
                }

                $sync = [string](Get-HAValue $row 'synchronization_state_desc' '')
                if (-not $sync) { continue }   # remote row not visible from this server (we are a secondary)

                $mode = [string](Get-HAValue $row 'availability_mode_desc' '')
                $flagged = $false

                if (Test-HATrue $row.is_suspended) {
                    $flagged = $true
                    $reason = [string](Get-HAValue $row 'suspend_reason_desc' '')
                    $hint = switch -Wildcard ($reason) {
                        'SUSPEND_FROM_USER' { 'Someone paused it manually (often during maintenance).' }
                        'SUSPEND_FROM_PARTNER' { 'It was paused because of the primary (forced failover or primary paused).' }
                        'SUSPEND_FROM_REDO' { 'An error happened while applying changes on the secondary - check its error log (often disk full / file growth problems).' }
                        'SUSPEND_FROM_APPLY' { 'An error happened while applying changes on the secondary - check its error log.' }
                        'SUSPEND_FROM_CAPTURE' { 'An error happened while capturing changes on the primary - check the primary error log.' }
                        'SUSPEND_FROM_RESTART' { 'It was paused before the database restarted.' }
                        'SUSPEND_FROM_UNDO' { 'An error happened during the undo phase after a failover.' }
                        'SUSPEND_FROM_REVALIDATION' { 'A log change mismatch was detected during reconnection - DBA attention needed.' }
                        default { 'Check the SQL error log on both servers.' }
                    }
                    $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object $obj `
                                -Title "Data movement SUSPENDED for $dbName on $rname" `
                                -Explanation "Copying changes for $dbName to $rname is paused (reason: $reason). $hint" `
                                -Impact "$rname is not receiving changes for $dbName and is falling behind. The transaction log on the primary cannot be cleared while this lasts and will grow." `
                                -Steps @('Find and fix the reason above (error log on the secondary).', "Resume data movement on $rname, then watch the queues drain on this screen.") `
                                -Queries @(
                                    (New-HAQuerySuggestion -RunOn "Secondary: $rname" -Title 'Local state of the database' -Sql "SELECT DB_NAME(database_id) AS db, synchronization_state_desc, is_suspended, suspend_reason_desc, redo_queue_size FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;"),
                                    (New-HAQuerySuggestion -Kind Fix -RunOn "Secondary: $rname" -Title 'Resume data movement' -Sql "ALTER DATABASE $dbLit SET HADR RESUME;")
                                ) -Links @((Get-HALink AgResume 'Microsoft: Resume an availability database'), $lnkIndex) `
                                -ConnectTo $rname -ConnectReason 'Resume has to be run on the secondary'))
                } elseif ($sync -eq 'NOT SYNCHRONIZING' -or $sync -eq 'NOT_SYNCHRONIZING') {
                    $flagged = $true
                    $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object $obj `
                                -Title "$dbName on $rname is NOT SYNCHRONIZING" `
                                -Explanation "The copy of $dbName on $rname is not receiving or applying changes, although the replica itself is connected. Common causes: the database on the secondary has a problem (disk full, file path missing), it is waiting on something, or it was just restarted." `
                                -Impact "Changes are not reaching $rname for this database; it is falling behind and the primary log may grow." `
                                -Steps @(
                                    "Check the SQL error log on $rname for errors mentioning $dbName (disk space, file growth, I/O).",
                                    "Check free disk space on $rname for the data and log drives.",
                                    'If the error is fixed, resume the database on the secondary.'
                                ) `
                                -Queries @(
                                    (New-HAQuerySuggestion -RunOn "Secondary: $rname" -Title 'Local AG database state' -Sql "SELECT DB_NAME(database_id) AS db, synchronization_state_desc, synchronization_health_desc, database_state_desc, is_suspended, suspend_reason_desc FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;"),
                                    (New-HAQuerySuggestion -RunOn "Secondary: $rname" -Title 'Free space on database volumes' -Sql "SELECT DISTINCT vs.volume_mount_point, vs.total_bytes/1048576 AS total_mb, vs.available_bytes/1048576 AS free_mb`r`nFROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs;"),
                                    (New-HAQuerySuggestion -Kind Fix -RunOn "Secondary: $rname" -Title 'Resume once the cause is fixed' -Sql "ALTER DATABASE $dbLit SET HADR RESUME;")
                                ) -Links @($lnkIndex) -ConnectTo $rname -ConnectReason 'Most of the evidence is on the secondary'))
                } elseif ($mode -eq 'SYNCHRONOUS_COMMIT' -and $sync -ne 'SYNCHRONIZED') {
                    $flagged = $true
                    $issues.Add((New-HAIssue -Severity Warning -Feature AG -Server $Server -Object $obj `
                                -Title "$dbName on $rname is $sync (should be SYNCHRONIZED)" `
                                -Explanation "$rname is set to synchronous mode, which normally keeps it exactly in step with the primary. Right now it is still catching up ($sync)." `
                                -Impact 'Until it is SYNCHRONIZED, an automatic failover to this replica cannot happen, and commits on the primary may be slower.' `
                                -Steps @('Usually temporary after a restart, resume, or a big operation (index rebuild). Refresh in a few minutes.', 'If it stays this way, check the send queue / redo queue numbers in the Databases grid and the network between the servers.') `
                                -Links @($lnkPerf)))
                }

                # queues & lag
                $sendKB = Get-HAValue $row 'log_send_queue_size'
                $redoKB = Get-HAValue $row 'redo_queue_size'
                $redoRate = Get-HAValue $row 'redo_rate'
                if ($null -ne $sendKB) {
                    $sendMB = [math]::Round([double]$sendKB / 1024, 1)
                    $sev = $null
                    if ($sendMB -ge $T.AgLogSendQueueCritMB) { $sev = 'Critical' } elseif ($sendMB -ge $T.AgLogSendQueueWarnMB) { $sev = 'Warning' }
                    if ($sev) {
                        $flagged = $true
                        $issues.Add((New-HAIssue -Severity $sev -Feature AG -Server $Server -Object $obj `
                                    -Title "$sendMB MB of changes waiting to be SENT to $rname ($dbName)" `
                                    -Explanation "The primary has $sendMB MB of changes for $dbName that have not yet reached $rname. Think of it as a queue at the post office: changes are piling up faster than they can be shipped." `
                                    -Impact 'If the primary failed right now, roughly this much recent work could be lost on that replica. The primary log also cannot shrink until this is sent.' `
                                    -Steps @(
                                        'Check whether a large operation is running on the primary (index rebuild, big data load) - the queue often drains afterwards.',
                                        'Check network bandwidth/latency between the servers (especially to a DR site).',
                                        'Watch the trend with auto-refresh: shrinking = catching up, growing = falling further behind.'
                                    ) `
                                    -Queries @(
                                        (New-HAQuerySuggestion -RunOn "Primary: $primaryName" -Title 'Send queue, send rate and estimated catch-up time' -Sql @"
SELECT ar.replica_server_name, DB_NAME(drs.database_id) AS db,
       drs.log_send_queue_size AS send_queue_kb, drs.log_send_rate AS send_rate_kb_s,
       CASE WHEN drs.log_send_rate > 0 THEN drs.log_send_queue_size / drs.log_send_rate END AS est_seconds_to_send
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.is_local = 0;
"@),
                                        (New-HAQuerySuggestion -RunOn "Primary: $primaryName" -Title 'Big operations running now' -Sql "SELECT session_id, command, DB_NAME(database_id) AS db, start_time, percent_complete, wait_type`r`nFROM sys.dm_exec_requests WHERE session_id > 50 AND command IN (N'ALTER INDEX', N'DBCC', N'BULK INSERT', N'CREATE INDEX', N'UPDATE', N'DELETE', N'INSERT');")
                                    ) -Links @($lnkPerf)))
                    }
                }
                if ($null -ne $redoKB) {
                    $redoMB = [math]::Round([double]$redoKB / 1024, 1)
                    $sev = $null
                    if ($redoMB -ge $T.AgRedoQueueCritMB) { $sev = 'Critical' } elseif ($redoMB -ge $T.AgRedoQueueWarnMB) { $sev = 'Warning' }
                    if ($sev) {
                        $flagged = $true
                        $eta = ''
                        if ($redoRate -and [double]$redoRate -gt 0) { $eta = " At the current speed it needs about $([math]::Ceiling([double]$redoKB / [double]$redoRate)) seconds to catch up." }
                        $issues.Add((New-HAIssue -Severity $sev -Feature AG -Server $Server -Object $obj `
                                    -Title "$redoMB MB of changes waiting to be APPLIED on $rname ($dbName)" `
                                    -Explanation "$rname has received the changes but has not finished applying ('redoing') them.$eta Common causes: a report/query on a readable secondary blocking the redo, slow disks on the secondary, or a big operation on the primary." `
                                    -Impact 'People reading from this secondary see older data, and a failover to it would take longer (it must finish applying first). No data is lost - it is already on the secondary.' `
                                    -Steps @(
                                        "Connect to $rname and check whether the redo thread is blocked by a reader (query below).",
                                        "Check disk latency on $rname.",
                                        'If a long report is blocking redo, ask its owner to stop it (the DBA can end the session if necessary).'
                                    ) `
                                    -Queries @(
                                        (New-HAQuerySuggestion -RunOn "Secondary: $rname" -Title 'Is redo blocked?' -Sql @"
SELECT r.session_id, DB_NAME(r.database_id) AS db, r.command, r.blocking_session_id, r.wait_type, r.wait_time
FROM sys.dm_exec_requests r
WHERE r.command IN (N'DB STARTUP', N'PARALLEL REDO TASK', N'PARALLEL REDO HELP TASK');
"@),
                                        (New-HAQuerySuggestion -RunOn "Secondary: $rname" -Title 'Redo queue and rate' -Sql "SELECT DB_NAME(database_id) AS db, redo_queue_size AS redo_queue_kb, redo_rate AS redo_kb_s, last_redone_time FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;")
                                    ) -Links @($lnkPerf) -ConnectTo $rname -ConnectReason 'Redo blocking is only visible on the secondary'))
                    }
                }
                if ($pri -and $null -ne (Get-HAValue $pri 'last_commit_time') -and $null -ne (Get-HAValue $row 'last_commit_time')) {
                    $lag = ([datetime]$pri.last_commit_time - [datetime]$row.last_commit_time).TotalSeconds
                    if ($lag -lt 0) { $lag = 0 }
                    $sev = $null
                    if ($lag -ge $T.AgLagCritSeconds) { $sev = 'Critical' } elseif ($lag -ge $T.AgLagWarnSeconds) { $sev = 'Warning' }
                    if ($sev -and -not $flagged) {
                        $issues.Add((New-HAIssue -Severity $sev -Feature AG -Server $Server -Object $obj `
                                    -Title "$rname is about $([math]::Round($lag)) s behind for $dbName" `
                                    -Explanation "The last change committed on the primary is about $([math]::Round($lag)) seconds newer than the last change on $rname. This is the 'how much could we lose' number (RPO)." `
                                    -Impact 'If the primary failed now and you had to fail over to this replica, roughly that much recent work could be lost.' `
                                    -Steps @('Look at the send queue and redo queue for this row in the Databases grid to see where the delay is (shipping vs applying).', 'Async replicas over a WAN normally lag a little; compare with your agreed RPO.') `
                                    -Links @($lnkPerf)))
                    }
                }
            }
        }

        # --- AG overall health with no specific finding ---
        $agHealth = [string](Get-HAValue $g 'ag_sync_health' '')
        $anyForAg = @($issues | Where-Object { $_.Object -like "AG $ag*" -and $_.Severity -ne 'Info' })
        if ($localRole -eq 'PRIMARY' -and $agHealth -and $agHealth -ne 'HEALTHY' -and $anyForAg.Count -eq 0) {
            $issues.Add((New-HAIssue -Severity Warning -Feature AG -Server $Server -Object "AG $ag" `
                        -Title "$ag reports $agHealth" `
                        -Explanation 'SQL Server says the AG is not fully healthy, but none of the specific checks here pin-pointed why. This can be a brief state during a restart, resume or failover.' `
                        -Impact 'Some replica or database may be behind.' `
                        -Steps @('Refresh in a minute.', 'Open the AG dashboard in SSMS (right-click the AG > Show Dashboard) for the policy that fails.') `
                        -Links @($lnkIndex)))
        }

        # --- listener ---
        $lst = @($Data.Listeners | Where-Object { $_.group_id -eq $g.group_id })
        if ($localRole -eq 'PRIMARY') {
            if ($lst.Count -eq 0) {
                $issues.Add((New-HAIssue -Severity Info -Feature AG -Server $Server -Object "AG $ag" `
                            -Title "$ag has no listener" `
                            -Explanation 'A listener is a virtual server name that always points to the current primary. Without it, applications connect to a specific server name and must be changed by hand after a failover.' `
                            -Impact 'Not an error - but failovers need manual connection changes.' `
                            -Links @((Get-HALink AgListener 'Microsoft: Create or configure an AG listener'))))
            } else {
                foreach ($ln in ($lst | Group-Object dns_name)) {
                    $online = @($ln.Group | Where-Object { [string]$_.ip_state -eq 'ONLINE' })
                    if ($online.Count -eq 0) {
                        $issues.Add((New-HAIssue -Severity Warning -Feature AG -Server $Server -Object "Listener $($ln.Name)" `
                                    -Title "Listener $($ln.Name) has no ONLINE IP address" `
                                    -Explanation 'The listener name applications use is not online on any IP address, so connections through the listener fail.' `
                                    -Impact 'Applications using the listener cannot connect (direct server names still work).' `
                                    -Steps @('Check the listener (Client Access Point) resource in Failover Cluster Manager and its error.', 'Common causes: IP conflict, missing permission for the cluster computer object in Active Directory/DNS.') `
                                    -Links @((Get-HALink AgListener 'Microsoft: Create or configure an AG listener'), $lnkIndex)))
                    }
                }
            }
        }
    }

    # --- redo blocked locally (only visible on a secondary) ---
    foreach ($b in @($Data.RedoBlocking)) {
        $issues.Add((New-HAIssue -Severity Critical -Feature AG -Server $Server -Object "$($b.database_name) redo" `
                    -Title "Redo for $($b.database_name) is BLOCKED by session $($b.blocking_session_id)" `
                    -Explanation "On this secondary, the process that applies changes from the primary is waiting for session $($b.blocking_session_id) (typically a long report/query reading the secondary). Until that session finishes, new changes pile up." `
                    -Impact 'Readers see increasingly old data; failover to this replica gets slower.' `
                    -Steps @('Identify who is running session ' + $b.blocking_session_id + ' (query below) and ask them to stop it.', 'As a last resort the DBA can end the session (KILL) - it only affects that reader.') `
                    -Queries @(
                        (New-HAQuerySuggestion -RunOn "Secondary: $Server" -Title 'Who is the blocker?' -Sql "SELECT s.session_id, s.login_name, s.host_name, s.program_name, r.start_time, r.command, t.text`r`nFROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id`r`nOUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.session_id = $([int]$b.blocking_session_id);"),
                        (New-HAQuerySuggestion -Kind Fix -RunOn "Secondary: $Server" -Title 'End the blocking reader (last resort)' -Sql "KILL $([int]$b.blocking_session_id);")
                    ) -Links @($lnkPerf)))
    }

    , $issues.ToArray()
}

function Get-HAAgTables {
    <# Friendly grid rows for the UI. #>
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Server, $Issues)
    $groups = @{}; foreach ($g in @($Data.Groups)) { $groups[[string]$g.group_id] = $g }
    $replicaRows = foreach ($r in @($Data.Replicas)) {
        $g = $groups[[string]$r.group_id]
        $health = 'OK'
        if ([string]$r.connected_state_desc -eq 'DISCONNECTED' -or [string]$r.synchronization_health_desc -eq 'NOT_HEALTHY') { $health = 'Critical' }
        elseif ([string]$r.synchronization_health_desc -eq 'PARTIALLY_HEALTHY') { $health = 'Warning' }
        [pscustomobject][ordered]@{
            Health               = $health
            AG                   = $g.ag_name
            Replica              = $r.replica_server_name
            Role                 = $(if ($r.role_desc) { $r.role_desc } else { '(not visible here)' })
            'Commit Mode'        = $r.availability_mode_desc
            Failover             = $r.failover_mode_desc
            'Readable Secondary' = $r.secondary_role_allow_connections_desc
            Connected            = $r.connected_state_desc
            'Sync Health'        = $r.synchronization_health_desc
            Operational          = $r.operational_state_desc
            'Last Connect Error' = $r.last_connect_error_description
            Endpoint             = $r.endpoint_url
        }
    }
    # primary last commit per db for lag
    $priCommit = @{}
    foreach ($d in @($Data.Databases)) {
        $g = $groups[[string]$d.group_id]
        if ($g -and [string]$d.replica_server_name -eq [string]$g.primary_replica -and $d.last_commit_time) { $priCommit[[string]$d.group_database_id] = $d.last_commit_time }
    }
    $dbRows = foreach ($d in @($Data.Databases)) {
        $g = $groups[[string]$d.group_id]
        $isPri = ($g -and [string]$d.replica_server_name -eq [string]$g.primary_replica)
        $lag = $null
        if (-not $isPri -and $d.last_commit_time -and $priCommit.ContainsKey([string]$d.group_database_id)) {
            $lag = [math]::Max(0, [math]::Round(([datetime]$priCommit[[string]$d.group_database_id] - [datetime]$d.last_commit_time).TotalSeconds))
        }
        $redoSec = $null
        if ($d.redo_queue_size -and $d.redo_rate -and [double]$d.redo_rate -gt 0) { $redoSec = [math]::Ceiling([double]$d.redo_queue_size / [double]$d.redo_rate) }
        $health = 'OK'
        if ([string]$d.synchronization_health_desc -eq 'NOT_HEALTHY' -or (Test-HATrue $d.is_suspended)) { $health = 'Critical' }
        elseif ([string]$d.synchronization_health_desc -eq 'PARTIALLY_HEALTHY' -or ($null -ne $d.is_database_joined -and -not (Test-HATrue $d.is_database_joined))) { $health = 'Warning' }
        [pscustomobject][ordered]@{
            Health                 = $health
            AG                     = $(if ($g) { $g.ag_name } else { '' })
            Database               = $d.database_name
            Replica                = $d.replica_server_name
            Role                   = $(if ($isPri) { 'PRIMARY' } else { 'SECONDARY' })
            'Sync State'           = $(if ($d.synchronization_state_desc) { $d.synchronization_state_desc } elseif (-not (Test-HATrue $d.is_database_joined)) { 'NOT JOINED' } else { '(not visible here)' })
            'Sync Health'          = $d.synchronization_health_desc
            Suspended              = $(if (Test-HATrue $d.is_suspended) { "YES ($($d.suspend_reason_desc))" } else { '' })
            'Send Queue MB'        = $(if ($null -ne $d.log_send_queue_size) { [math]::Round([double]$d.log_send_queue_size / 1024, 1) } else { $null })
            'Send KB/s'            = $d.log_send_rate
            'Redo Queue MB'        = $(if ($null -ne $d.redo_queue_size) { [math]::Round([double]$d.redo_queue_size / 1024, 1) } else { $null })
            'Redo KB/s'            = $d.redo_rate
            'Est. Data Loss (s)'   = $lag
            'Est. Redo Time (s)'   = $redoSec
            'Failover Ready'       = $(if (Test-HATrue $d.is_failover_ready) { 'Yes' } else { 'No' })
            'Last Commit'          = $d.last_commit_time
        }
    }
    $lstRows = foreach ($l in @($Data.Listeners)) {
        $g = $groups[[string]$l.group_id]
        [pscustomobject][ordered]@{
            Health    = $(if ([string]$l.ip_state -eq 'ONLINE') { 'OK' } else { 'Info' })
            AG        = $(if ($g) { $g.ag_name } else { '' })
            Listener  = $l.dns_name
            Port      = $l.port
            IP        = $l.ip_address
            'IP State'= $l.ip_state
        }
    }
    $clRows = @()
    foreach ($c in @($Data.Cluster)) { $clRows += [pscustomobject][ordered]@{ Health = $(if ($c.quorum_state_desc -eq 'NORMAL_QUORUM') { 'OK' } else { 'Critical' }); Item = "Cluster $($c.cluster_name)"; Type = $c.quorum_type_desc; State = $c.quorum_state_desc; Votes = $null } }
    foreach ($m in @($Data.Members)) { $clRows += [pscustomobject][ordered]@{ Health = $(if ($m.member_state_desc -eq 'UP') { 'OK' } else { 'Warning' }); Item = $m.member_name; Type = $m.member_type_desc; State = $m.member_state_desc; Votes = $m.number_of_quorum_votes } }

    $tables = [ordered]@{}
    $tables['Replicas'] = @($replicaRows)
    $tables['Databases'] = @($dbRows)
    $tables['Listeners'] = @($lstRows)
    $tables['Cluster'] = @($clRows)
    $tables
}

function Get-HAAgReport {
    param([Parameter(Mandatory)]$SqlConnection, [Parameter(Mandatory)]$ServerInfo, $Thresholds)
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $r = New-HAFeatureResult -Feature AG
    $server = [string]$ServerInfo.server_name
    if (-not (Test-HATrue $ServerInfo.is_hadr_enabled)) {
        $r.Summary = 'Always On availability groups are not enabled on this instance.'
        return $r
    }
    $data = Get-HAAgData -SqlConnection $SqlConnection -Result $r -Timeout $Thresholds.QueryTimeoutSeconds
    $groups = @($data.Groups)
    if ($groups.Count -eq 0) {
        $r.Summary = 'Always On is enabled, but this server is not part of any availability group.'
        Add-HACollectErrorIssues -Result $r -Server $server
        return $r
    }
    $r.Configured = $true
    $parts = @()
    foreach ($g in $groups) {
        $local = @($data.Replicas | Where-Object { $_.group_id -eq $g.group_id -and (Test-HATrue $_.is_local) }) | Select-Object -First 1
        $role = [string](Get-HAValue $local 'role_desc' 'UNKNOWN')
        $r.Roles.Add("AG $($g.ag_name): $role")
        $h = [string](Get-HAValue $g 'ag_sync_health' '')
        $parts += "$($g.ag_name) - this server is $role, primary is $($g.primary_replica)$(if ($h) { ", health $h" })"
    }
    $r.Summary = ($parts -join '; ')
    foreach ($i in (Get-HAAgIssues -Data $data -Server $server -Thresholds $Thresholds)) { $r.Issues.Add($i) }
    Add-HACollectErrorIssues -Result $r -Server $server
    $r.Tables = Get-HAAgTables -Data $data -Server $server
    $r
}

# ======================= SqlHAMonitor.LogShipping =======================
<#
    SqlHAMonitor.LogShipping
    ------------------------
    Log shipping = 3 SQL Agent jobs:  BACKUP (on primary)  ->  COPY (on secondary)  ->  RESTORE (on secondary)
    What each server can see:
      * PRIMARY  : its backup job and the list of secondaries - NOT their copy/restore progress
      * SECONDARY: copy + restore progress for its databases, and which server is primary
      * MONITOR  : (optional, set up at configuration time) progress of everything
    So when connected to a primary, the monitor points you to each secondary (or the monitor server).
#>


function Get-HALogShippingData {
    param([Parameter(Mandatory)]$SqlConnection, [Parameter(Mandatory)]$Result, $Thresholds)
    $to = $Thresholds.QueryTimeoutSeconds
    $d = @{}

    $d.Primary = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log shipping primary databases' -Query @"
SELECT  p.primary_id, p.primary_database, p.backup_directory, p.backup_share, p.backup_job_id, p.monitor_server,
        p.last_backup_file, p.last_backup_date,
        mp.backup_threshold, mp.threshold_alert_enabled,
        CASE WHEN mp.last_backup_date_utc IS NOT NULL THEN DATEDIFF(MINUTE, mp.last_backup_date_utc, GETUTCDATE())
             WHEN p.last_backup_date IS NOT NULL      THEN DATEDIFF(MINUTE, p.last_backup_date, GETDATE()) END AS minutes_since_backup,
        d.state_desc, d.recovery_model_desc
FROM    msdb.dbo.log_shipping_primary_databases p
LEFT JOIN msdb.dbo.log_shipping_monitor_primary mp ON mp.primary_id = p.primary_id
LEFT JOIN sys.databases d ON d.name = p.primary_database
"@

    $d.PrimarySecondaries = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log shipping secondaries list' -Query @"
SELECT ps.primary_id, ps.secondary_server, ps.secondary_database FROM msdb.dbo.log_shipping_primary_secondaries ps
"@

    $d.Secondary = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log shipping secondary databases' -Query @"
SELECT  s.secondary_id, s.primary_server, s.primary_database, s.backup_source_directory, s.backup_destination_directory,
        s.copy_job_id, s.restore_job_id, s.monitor_server,
        sd.secondary_database, sd.restore_delay, sd.restore_mode, sd.disconnect_users,
        ms.restore_threshold, ms.threshold_alert_enabled, ms.last_copied_file, ms.last_restored_file, ms.last_restored_latency,
        CASE WHEN ms.last_copied_date_utc IS NOT NULL THEN DATEDIFF(MINUTE, ms.last_copied_date_utc, GETUTCDATE())
             WHEN s.last_copied_date IS NOT NULL      THEN DATEDIFF(MINUTE, s.last_copied_date, GETDATE()) END AS minutes_since_copy,
        CASE WHEN ms.last_restored_date_utc IS NOT NULL THEN DATEDIFF(MINUTE, ms.last_restored_date_utc, GETUTCDATE())
             WHEN sd.last_restored_date IS NOT NULL     THEN DATEDIFF(MINUTE, sd.last_restored_date, GETDATE()) END AS minutes_since_restore,
        db.state_desc, db.is_in_standby
FROM    msdb.dbo.log_shipping_secondary s
JOIN    msdb.dbo.log_shipping_secondary_databases sd ON sd.secondary_id = s.secondary_id
LEFT JOIN msdb.dbo.log_shipping_monitor_secondary ms ON ms.secondary_id = s.secondary_id AND ms.secondary_database = sd.secondary_database
LEFT JOIN sys.databases db ON db.name = sd.secondary_database
"@

    # What a MONITOR server knows about other servers (also contains local rows - filtered in analysis)
    $d.MonitorPrimary = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log shipping monitor (primaries)' -Query @"
SELECT  primary_id, primary_server, primary_database, backup_threshold, threshold_alert_enabled, last_backup_file,
        DATEDIFF(MINUTE, last_backup_date_utc, GETUTCDATE()) AS minutes_since_backup
FROM    msdb.dbo.log_shipping_monitor_primary
"@
    $d.MonitorSecondary = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log shipping monitor (secondaries)' -Query @"
SELECT  secondary_id, secondary_server, secondary_database, primary_server, primary_database, restore_threshold,
        threshold_alert_enabled, last_copied_file, last_restored_file, last_restored_latency,
        DATEDIFF(MINUTE, last_copied_date_utc, GETUTCDATE())   AS minutes_since_copy,
        DATEDIFF(MINUTE, last_restored_date_utc, GETUTCDATE()) AS minutes_since_restore
FROM    msdb.dbo.log_shipping_monitor_secondary
"@

    $d.Errors = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log shipping errors' -Parameters @{ '@h' = [int]$Thresholds.LsErrorLookbackHours } -Query @"
SELECT TOP (200) agent_type, database_name, log_time, message,
       DATEDIFF(MINUTE, log_time_utc, GETUTCDATE()) AS minutes_ago
FROM   msdb.dbo.log_shipping_monitor_error_detail
WHERE  log_time_utc >= DATEADD(HOUR, -@h, GETUTCDATE())
ORDER BY log_time_utc DESC
"@

    $d.OtherLogBackups = @()
    if (@($d.Primary).Count -gt 0) {
        $d.OtherLogBackups = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Recent log backups (msdb)' -Optional -Query @"
SELECT  bs.database_name, bs.backup_finish_date, bs.is_copy_only, bmf.physical_device_name, bmf.device_type
FROM    msdb.dbo.backupset bs
JOIN    msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE   bs.type = 'L'
  AND   bs.backup_finish_date >= DATEADD(HOUR, -24, GETDATE())
  AND   bs.database_name IN (SELECT p.primary_database FROM msdb.dbo.log_shipping_primary_databases p)
"@
    }

    $jobIds = @()
    foreach ($p in @($d.Primary)) { if ($p.backup_job_id) { $jobIds += [string]$p.backup_job_id } }
    foreach ($s in @($d.Secondary)) { if ($s.copy_job_id) { $jobIds += [string]$s.copy_job_id }; if ($s.restore_job_id) { $jobIds += [string]$s.restore_job_id } }
    $d.Jobs = @()
    if ($jobIds.Count) {
        try { $d.Jobs = Get-HAJobStatus -SqlConnection $SqlConnection -JobIds $jobIds }
        catch { $Result.Errors.Add([pscustomobject]@{ Label = 'SQL Agent job status'; Message = $_.Exception.Message; Number = (Get-HASqlErrorNumber $_.Exception); Optional = $false }) }
    }
    $d
}

function Get-HALsErrorHint {
    <# Translates common log shipping error text into plain English. #>
    param([string]$Message)
    $m = [string]$Message
    if ($m -match 'Access is denied|access denied|Operating system error 5') { return 'Permission problem: the SQL Agent service account (or job proxy) cannot read/write the backup folder or network share.' }
    if ($m -match 'network path was not found|network name is no longer available|Operating system error 53|Operating system error 64') { return 'Network problem: the backup share cannot be reached from this server.' }
    if ($m -match 'cannot find the path|cannot find the file|Operating system error (2|3)\b|Could not find') { return 'A folder or file is missing: the configured path may be wrong, or a backup file was deleted/moved before it was copied or restored.' }
    if ($m -match 'too recent to apply|includes LSN|LSN .* is too|earlier log backup') { return 'A gap in the chain of log backups: a backup file is missing (often because someone took an extra log backup outside log shipping, or a file was deleted). The secondary cannot skip it.' }
    if ($m -match 'Exclusive access could not be obtained|database is in use') { return 'Users are connected to the read-only (standby) secondary database, and the restore job is set not to disconnect them, so it waits.' }
    if ($m -match 'not enough space|disk is full|There is insufficient|Operating system error 112') { return 'Disk space ran out on the backup/copy folder or database drive.' }
    if ($m -match 'Login failed|login failed') { return 'A login failed - usually the connection to the monitor server or a linked server.' }
    if ($m -match 'Skipping log backup file') { return 'Informational: the restore job skipped a file (already applied, or waiting for the configured restore delay). Usually harmless on its own.' }
    if ($m -match 'Could not apply log backup file|restore operation') { return 'A restore failed - read the full message; together with other messages it usually names the root cause.' }
    return $null
}

function Get-HALogShippingIssues {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Server, $Thresholds, [string]$AgentStatus = 'Unknown')
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $issues = ([System.Collections.Generic.List[object]]::new())
    $T = $Thresholds
    $lnkMon = Get-HALink LsMonitorTsql 'Microsoft: Monitor log shipping (T-SQL)'
    $lnkRpt = Get-HALink LsReport 'Microsoft: Log shipping status report in SSMS'
    $lnkTbl = Get-HALink LsTables 'Microsoft: Log shipping tables and procedures'
    $lnkErr = Get-HALink LsErrorDetail 'Microsoft: log_shipping_monitor_error_detail'

    $primaries = @($Data.Primary)
    $secondaries = @($Data.Secondary)
    $jobs = @{}; foreach ($j in @($Data.Jobs)) { $jobs[([string]$j.job_id).ToLower()] = $j }
    $srvU = $Server.ToUpper()

    if (($primaries.Count -gt 0 -or $secondaries.Count -gt 0) -and $AgentStatus -match 'Stop') {
        $issues.Add((New-HAAgentStoppedIssue -Server $Server -Feature LS -Why 'Log shipping backup, copy and restore are all SQL Agent jobs - none of them will run.'))
    }

    # ---------------- PRIMARY ----------------
    foreach ($p in $primaries) {
        $db = [string]$p.primary_database
        $dbLit = ConvertTo-HASqlLiteral $db
        $obj = "Primary $db"
        $thr = Get-HAValue $p 'backup_threshold' $T.LsDefaultBackupThresholdMin
        $age = Get-HAValue $p 'minutes_since_backup'

        $state = [string](Get-HAValue $p 'state_desc' '')
        if ($state -and $state -ne 'ONLINE') {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj -Title "Primary database $db is $state" `
                        -Explanation "The source database for log shipping is not online (state $state), so no log backups can be taken." `
                        -Impact 'Log shipping is stopped for this database.' -Steps @('Check the SQL Server error log for this database.') -Links @($lnkMon)))
        }
        $rm = [string](Get-HAValue $p 'recovery_model_desc' '')
        if ($rm -eq 'SIMPLE') {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj -Title "$db is in SIMPLE recovery - log shipping is broken" `
                        -Explanation 'Log shipping works by backing up the transaction log. In SIMPLE recovery mode there is no log to back up, so the backup job fails and the chain is broken.' `
                        -Impact 'Secondaries stop getting changes. After switching back to FULL, the secondary normally has to be re-initialized from a new full (or differential) backup.' `
                        -Steps @('Find out who/what changed the recovery model (often a maintenance script or a restore).', 'Switch back to FULL, take a full or differential backup, and re-initialize the secondary from it.') `
                        -Queries @(
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Recovery model' -Sql "SELECT name, recovery_model_desc FROM sys.databases WHERE name = $dbLit;"),
                            (New-HAQuerySuggestion -Kind Fix -RunOn $Server -Title 'Switch back to FULL (then re-seed secondary)' -Sql "ALTER DATABASE $(ConvertTo-HASqlIdentifier $db) SET RECOVERY FULL;")
                        ) -Links @((Get-HALink LsConfigure 'Microsoft: Configure log shipping'))))
        }

        $job = $null
        if ($p.backup_job_id) { $job = $jobs[([string]$p.backup_job_id).ToLower()] }
        $jobIssue = $null
        if ($job) { $jobIssue = New-HAJobIssue -Job $job -Feature LS -Server $Server -Purpose "log shipping BACKUP job for $db" -WhatItDoes 'This job takes the log backups that the secondaries copy and restore.' -Links @($lnkMon) }
        if ($jobIssue) { $issues.Add($jobIssue) }

        if ($null -eq $age -or [double]$age -gt [double]$thr) {
            $ageTxt = Format-HAMinutes $age
            $jobTxt = if ($job) { "Backup job '$($job.job_name)' last run: $(Get-HAJobOutcomeText $job)." } else { 'The backup job could not be found.' }
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj `
                        -Title "No log backup for $db in $ageTxt (limit $thr min)" `
                        -Explanation "Log shipping needs a log backup on the primary regularly. The last one for $db was $ageTxt ago, more than the $thr-minute limit. $jobTxt" `
                        -Impact 'Secondaries cannot receive anything newer than the last backup, so they fall behind. The transaction log on the primary also keeps growing.' `
                        -Steps @(
                            'Check SQL Server Agent is running and the backup job is enabled and succeeding (history query below).',
                            "Check the backup folder ($($p.backup_directory)) exists, has free space, and the Agent account can write to it.",
                            'Once fixed, start the backup job manually and refresh.'
                        ) `
                        -Queries @(
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Last log backups of this database' -Sql "SELECT TOP (10) bs.backup_finish_date, bmf.physical_device_name, bs.is_copy_only`r`nFROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id`r`nWHERE bs.database_name = $dbLit AND bs.type = 'L' ORDER BY bs.backup_finish_date DESC;"),
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Log shipping status for the primary (built-in report proc)' -Sql "EXEC msdb.dbo.sp_help_log_shipping_monitor_primary @primary_server = $(ConvertTo-HASqlLiteral $Server), @primary_database = $dbLit;")
                        ) -Links @($lnkMon, $lnkRpt)))
        }

        # log backups outside log shipping (they break the chain unless copy-only)
        $dirs = @()
        foreach ($x in @($p.backup_directory, $p.backup_share)) { if ($x) { $dirs += ([string]$x).TrimEnd('\', '/').ToLower() } }
        $foreign = @()
        foreach ($b in @($Data.OtherLogBackups | Where-Object { [string]$_.database_name -eq $db })) {
            if (Test-HATrue $b.is_copy_only) { continue }
            $path = ([string]$b.physical_device_name).ToLower()
            $inside = $false
            foreach ($dd in $dirs) { if ($path.StartsWith($dd)) { $inside = $true } }
            if (-not $inside) { $foreign += $b }
        }
        if ($foreign.Count -gt 0) {
            $list = ($foreign | Select-Object -First 5 | ForEach-Object { "  $($_.backup_finish_date)  $($_.physical_device_name)" }) -join "`r`n"
            $issues.Add((New-HAIssue -Severity Warning -Feature LS -Server $Server -Object $obj `
                        -Title "$($foreign.Count) log backup(s) of $db taken OUTSIDE log shipping in the last 24h" `
                        -Explanation "Each log backup contains the changes since the previous one, like numbered pages of a book. These backups were written somewhere other than the log shipping folder ($($p.backup_directory)), so the secondary never sees those pages and restores will stop with a 'too recent to apply' error.`r`n$list" `
                        -Impact 'The secondary gets stuck at the gap until the missing file(s) are restored manually or it is re-initialized.' `
                        -Steps @(
                            'Find the job/tool taking these backups (maintenance plan, 3rd-party backup software, VM snapshot tool) and disable log backups for this database there - or make them COPY_ONLY.',
                            'To repair: copy the missing file(s) into the secondary''s copy folder (or restore them manually WITH NORECOVERY/STANDBY in order), then let the restore job continue.'
                        ) `
                        -Queries @((New-HAQuerySuggestion -RunOn $Server -Title 'All log backups in the last 24h with who took them' -Sql "SELECT bs.backup_finish_date, bs.user_name, bs.is_copy_only, bmf.physical_device_name, bs.first_lsn, bs.last_lsn`r`nFROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id`r`nWHERE bs.database_name = $dbLit AND bs.type = 'L' AND bs.backup_finish_date >= DATEADD(HOUR, -24, GETDATE())`r`nORDER BY bs.backup_finish_date;")) `
                        -Links @($lnkMon)))
        }

        # point to secondaries for copy/restore status (unless this server also has monitor data for them)
        foreach ($s in @($Data.PrimarySecondaries | Where-Object { $_.primary_id -eq $p.primary_id })) {
            $have = @($Data.MonitorSecondary | Where-Object { ([string]$_.secondary_server).ToUpper() -eq ([string]$s.secondary_server).ToUpper() -and [string]$_.secondary_database -eq [string]$s.secondary_database })
            if ($have.Count -eq 0) {
                $issues.Add((New-HAIssue -Severity Info -Feature LS -Server $Server -Object $obj `
                            -Title "Copy/restore status of $db lives on secondary $($s.secondary_server)" `
                            -Explanation "This primary ships $db to $($s.secondary_server) (database $($s.secondary_database)). The primary only knows about its own backups; whether files are being copied and restored is recorded on the secondary$(if ($p.monitor_server) { " (and on the monitor server $($p.monitor_server))" })." `
                            -Impact 'Not a problem - connect to the secondary to see the rest of the chain.' `
                            -ConnectTo ([string]$s.secondary_server) -ConnectReason "Secondary for $db - copy and restore jobs run there"))
            }
        }
    }

    # ---------------- SECONDARY ----------------
    foreach ($s in $secondaries) {
        $db = [string]$s.secondary_database
        $dbLit = ConvertTo-HASqlLiteral $db
        $obj = "Secondary $db (from $($s.primary_server).$($s.primary_database))"
        $thr = [double](Get-HAValue $s 'restore_threshold' $T.LsDefaultRestoreThresholdMin)
        $delay = [double](Get-HAValue $s 'restore_delay' 0)
        $copyAge = Get-HAValue $s 'minutes_since_copy'
        $restAge = Get-HAValue $s 'minutes_since_restore'

        $state = [string](Get-HAValue $s 'state_desc' '')
        $standby = Test-HATrue (Get-HAValue $s 'is_in_standby' 0)
        if (-not $state) {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj -Title "Secondary database $db does not exist on this server" `
                        -Explanation 'Log shipping is configured for this database, but the database itself is missing (dropped or renamed).' `
                        -Impact 'Nothing can be restored; log shipping for it is broken.' -Steps @('Re-initialize: restore a full backup of the primary WITH NORECOVERY (or STANDBY) under this name.') -Links @($lnkTbl)))
        } elseif ($state -eq 'ONLINE' -and -not $standby) {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj -Title "Secondary $db was RECOVERED (fully online) - log shipping is broken" `
                        -Explanation 'A log shipping secondary must stay in RESTORING or read-only STANDBY mode so it can keep accepting log backups. This one was brought fully online (someone ran RESTORE ... WITH RECOVERY, or it was used for a failover/test).' `
                        -Impact 'No further log backups can be applied. If this was not a planned failover, the secondary must be re-initialized from a new full backup.' `
                        -Steps @('Confirm whether this was an intentional failover / DR test.', 'If not, re-initialize: restore a new full backup of the primary WITH NORECOVERY (or STANDBY) and let the jobs continue.') `
                        -Queries @((New-HAQuerySuggestion -RunOn $Server -Title 'When and how was it last restored?' -Sql "SELECT TOP (5) rh.restore_date, rh.restore_type, rh.recovery, rh.user_name, bmf.physical_device_name`r`nFROM msdb.dbo.restorehistory rh JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id`r`nJOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id`r`nWHERE rh.destination_database_name = $dbLit ORDER BY rh.restore_date DESC;")) `
                        -Links @((Get-HALink LsConfigure 'Microsoft: Configure log shipping'))))
        } elseif ($state -ne 'RESTORING' -and $state -ne 'ONLINE') {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj -Title "Secondary database $db is $state" `
                        -Explanation "The secondary database is in an unexpected state ($state)." -Impact 'Restores cannot run.' -Steps @('Check the SQL Server error log on this server for the database.') -Links @($lnkMon)))
        }

        $copyJob = $null; $restJob = $null
        if ($s.copy_job_id) { $copyJob = $jobs[([string]$s.copy_job_id).ToLower()] }
        if ($s.restore_job_id) { $restJob = $jobs[([string]$s.restore_job_id).ToLower()] }
        if ($copyJob) { $ji = New-HAJobIssue -Job $copyJob -Feature LS -Server $Server -Purpose "log shipping COPY job for $db" -WhatItDoes "This job copies new log backup files from the primary's share ($($s.backup_source_directory)) to this server ($($s.backup_destination_directory))." -Links @($lnkMon); if ($ji) { $issues.Add($ji) } }
        if ($restJob) { $ji = New-HAJobIssue -Job $restJob -Feature LS -Server $Server -Purpose "log shipping RESTORE job for $db" -WhatItDoes 'This job applies the copied log backups to the secondary database.' -Links @($lnkMon); if ($ji) { $issues.Add($ji) } }

        $copyLate = ($null -eq $copyAge -or [double]$copyAge -gt $thr)
        $restLate = ($null -eq $restAge -or [double]$restAge -gt ($thr + $delay))

        if ($restLate) {
            if (-not $copyLate) {
                $cause = "New files ARE arriving (last copy $(Format-HAMinutes $copyAge) ago), so the problem is the RESTORE step on this server: the restore job failing, a missing file in the chain, or users connected to a standby database blocking it."
                $steps = @(
                    "Check the restore job history and the log shipping errors below/in the Errors grid.",
                    $(if ($standby -and -not (Test-HATrue $s.disconnect_users)) { 'This database is in STANDBY (readable) mode and the restore job does NOT disconnect users - check for open sessions in the database.' } else { 'Check that the next expected file exists in the copy folder.' }),
                    "If the error says the log is 'too recent to apply', a file is missing - look on the primary for log backups taken outside log shipping."
                )
                $conn = ''; $connReason = ''
            } else {
                $cause = "No new files are arriving either (last copy $(Format-HAMinutes $copyAge) ago). The problem is upstream: the BACKUP on the primary ($($s.primary_server)) or the COPY from its share."
                $steps = @(
                    "Check the copy job here and whether this server can reach the share $($s.backup_source_directory) (permissions for the SQL Agent account, network).",
                    "Connect to the primary $($s.primary_server) and check its backup job is running and producing files.",
                    'Check disk space in the copy destination folder.'
                )
                $conn = [string]$s.primary_server; $connReason = 'Check the backup side of the chain on the primary'
            }
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object $obj `
                        -Title "$db last restored $(Format-HAMinutes $restAge) ago (limit $($thr + $delay) min)" `
                        -Explanation ("The secondary copy of $($s.primary_database) has not had a log backup restored for $(Format-HAMinutes $restAge)" + $(if ($delay -gt 0) { " (a restore delay of $delay min is configured, which is allowed for)" } else { '' }) + ". $cause") `
                        -Impact 'The secondary is out of date. If you had to switch to it now, everything since the last restore would be missing.' `
                        -Steps $steps `
                        -Queries @(
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Secondary status (built-in report proc)' -Sql "EXEC msdb.dbo.sp_help_log_shipping_monitor_secondary @secondary_server = $(ConvertTo-HASqlLiteral $Server), @secondary_database = $dbLit;"),
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Recent log shipping errors for this database' -Sql "SELECT TOP (50) log_time, CASE agent_type WHEN 0 THEN 'Backup' WHEN 1 THEN 'Copy' WHEN 2 THEN 'Restore' END AS step, message`r`nFROM msdb.dbo.log_shipping_monitor_error_detail WHERE database_name = $dbLit ORDER BY log_time DESC;"),
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Sessions using the standby database (block restores)' -Sql "SELECT session_id, login_name, host_name, program_name, last_request_end_time FROM sys.dm_exec_sessions WHERE database_id = DB_ID($dbLit);")
                        ) -Links @($lnkMon, $lnkRpt, $lnkErr) -ConnectTo $conn -ConnectReason $connReason))
        } elseif ($copyLate) {
            $issues.Add((New-HAIssue -Severity Warning -Feature LS -Server $Server -Object $obj `
                        -Title "No new log backup copied for $db in $(Format-HAMinutes $copyAge)" `
                        -Explanation "Restores are still within the limit, but no new backup file has been copied from $($s.backup_source_directory) for $(Format-HAMinutes $copyAge). Either the primary is not producing backups or the copy is failing." `
                        -Impact 'If this continues the secondary will fall behind and breach the restore limit.' `
                        -Steps @('Check the copy job history on this server.', "Check the backup job on the primary $($s.primary_server).") `
                        -Links @($lnkMon) -ConnectTo ([string]$s.primary_server) -ConnectReason 'Check the backup job on the primary'))
        }

    }
    # one pointer per primary server (not one per database)
    foreach ($pg in ($secondaries | Group-Object { [string]$_.primary_server })) {
        $list = ($pg.Group | ForEach-Object { "$($_.secondary_database) (from $($_.primary_database))" }) -join ', '
        $issues.Add((New-HAIssue -Severity Info -Feature LS -Server $Server -Object "Secondaries of $($pg.Name)" `
                    -Title "This server is a log shipping secondary of $($pg.Name)" `
                    -Explanation "Databases restored here from $($pg.Name): $list. The backup job, the backup chain and 'outside' log backups can only be checked on the primary." `
                    -ConnectTo ([string]$pg.Name) -ConnectReason 'Primary - backup job and backup chain'))
    }

    # ---------------- MONITOR server view of OTHER servers ----------------
    $localPriIds = @($primaries | ForEach-Object { [string]$_.primary_id })
    foreach ($mp in @($Data.MonitorPrimary)) {
        if ($localPriIds -contains [string]$mp.primary_id -or ([string]$mp.primary_server).ToUpper() -eq $srvU) { continue }
        $thr = Get-HAValue $mp 'backup_threshold' $T.LsDefaultBackupThresholdMin
        $age = Get-HAValue $mp 'minutes_since_backup'
        if ($null -eq $age -or [double]$age -gt [double]$thr) {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object "Monitor: $($mp.primary_server).$($mp.primary_database)" `
                        -Title "[Monitor] $($mp.primary_server): no log backup of $($mp.primary_database) in $(Format-HAMinutes $age)" `
                        -Explanation "This server is the log shipping MONITOR. It reports that the primary $($mp.primary_server) has not backed up $($mp.primary_database) for longer than the $thr-minute limit." `
                        -Impact 'Secondaries cannot get anything newer.' -Steps @("Connect to $($mp.primary_server) to see the backup job and the reason.") `
                        -Links @($lnkMon) -ConnectTo ([string]$mp.primary_server) -ConnectReason 'Primary - backup job runs there'))
        }
    }
    $localSecIds = @($secondaries | ForEach-Object { [string]$_.secondary_id })
    foreach ($ms in @($Data.MonitorSecondary)) {
        if ($localSecIds -contains [string]$ms.secondary_id -or ([string]$ms.secondary_server).ToUpper() -eq $srvU) { continue }
        $thr = [double](Get-HAValue $ms 'restore_threshold' $T.LsDefaultRestoreThresholdMin)
        $age = Get-HAValue $ms 'minutes_since_restore'
        if ($null -eq $age -or [double]$age -gt $thr) {
            $issues.Add((New-HAIssue -Severity Critical -Feature LS -Server $Server -Object "Monitor: $($ms.secondary_server).$($ms.secondary_database)" `
                        -Title "[Monitor] $($ms.secondary_server): $($ms.secondary_database) last restored $(Format-HAMinutes $age) ago" `
                        -Explanation "This server is the log shipping MONITOR. It reports that the secondary $($ms.secondary_server) has not restored a log backup for $($ms.secondary_database) within the $thr-minute limit (last copy: $(Format-HAMinutes $ms.minutes_since_copy) ago). Note: a configured restore delay on the secondary is not visible here." `
                        -Impact 'That secondary is out of date.' -Steps @("Connect to $($ms.secondary_server) to see the copy/restore jobs and errors.") `
                        -Links @($lnkMon) -ConnectTo ([string]$ms.secondary_server) -ConnectReason 'Secondary - copy and restore jobs run there'))
        }
    }

    # ---------------- recent errors ----------------
    $agentNames = @{ '0' = 'Backup'; '1' = 'Copy'; '2' = 'Restore' }
    foreach ($eg in (@($Data.Errors) | Group-Object { "$($_.agent_type)|$($_.database_name)" })) {
        $first = $eg.Group[0]
        $step = $agentNames[[string]$first.agent_type]; if (-not $step) { $step = 'Agent' }
        $msgs = @($eg.Group | Select-Object -First 6 | ForEach-Object { "  $($_.log_time): $($_.message)" })
        $hints = @($eg.Group | ForEach-Object { Get-HALsErrorHint $_.message } | Where-Object { $_ } | Select-Object -Unique)
        $onlySkips = ($hints.Count -eq 1 -and $hints[0] -like 'Informational*')
        $issues.Add((New-HAIssue -Severity $(if ($onlySkips) { 'Info' } else { 'Warning' }) -Feature LS -Server $Server -Object "$step - $($first.database_name)" `
                    -Title "$($eg.Count) log shipping $step message(s) for $($first.database_name) in the last $($T.LsErrorLookbackHours)h" `
                    -Explanation ($(if ($hints.Count) { "In plain words: " + ($hints -join ' ') + "`r`n`r`n" } else { '' }) + "Most recent messages:`r`n" + ($msgs -join "`r`n")) `
                    -Impact 'Read together with the status above - if the database is still within its limits these may be transient.' `
                    -Steps @('Read the newest message first - SQL Server usually puts the root cause in the last 2-3 lines.', 'Fix the cause and re-run the failing job.') `
                    -Queries @((New-HAQuerySuggestion -RunOn $Server -Title 'Full error detail' -Sql "SELECT TOP (100) log_time, CASE agent_type WHEN 0 THEN 'Backup' WHEN 1 THEN 'Copy' WHEN 2 THEN 'Restore' END AS step, database_name, message, source`r`nFROM msdb.dbo.log_shipping_monitor_error_detail ORDER BY log_time DESC;")) `
                    -Links @($lnkErr, $lnkMon)))
    }
    , $issues.ToArray()
}

function Get-HALogShippingTables {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Server, $Thresholds)
    $T = $Thresholds
    $jobs = @{}; foreach ($j in @($Data.Jobs)) { $jobs[([string]$j.job_id).ToLower()] = $j }
    $jobTxt = { param($id) if (-not $id) { return '' }; $j = $jobs[([string]$id).ToLower()]; if (-not $j) { return '(not found)' }; $e = if (Test-HATrue $j.enabled) { '' } else { 'DISABLED, ' }; "$e$(Get-HAJobOutcomeText $j)" }

    $pri = foreach ($p in @($Data.Primary)) {
        $thr = Get-HAValue $p 'backup_threshold' $T.LsDefaultBackupThresholdMin
        $age = Get-HAValue $p 'minutes_since_backup'
        $secs = @($Data.PrimarySecondaries | Where-Object { $_.primary_id -eq $p.primary_id } | ForEach-Object { "$($_.secondary_server).$($_.secondary_database)" }) -join ', '
        [pscustomobject][ordered]@{
            Health                = $(if ($null -eq $age -or [double]$age -gt [double]$thr) { 'Critical' } else { 'OK' })
            Database              = $p.primary_database
            'Min Since Backup'    = $age
            'Threshold (min)'     = $thr
            'Backup Job'          = (& $jobTxt $p.backup_job_id)
            'Last Backup File'    = $p.last_backup_file
            'Backup Folder'       = $p.backup_directory
            Secondaries           = $secs
            'Monitor Server'      = $p.monitor_server
            'Recovery Model'      = $p.recovery_model_desc
        }
    }
    $sec = foreach ($s in @($Data.Secondary)) {
        $thr = [double](Get-HAValue $s 'restore_threshold' $T.LsDefaultRestoreThresholdMin)
        $delay = [double](Get-HAValue $s 'restore_delay' 0)
        $ra = Get-HAValue $s 'minutes_since_restore'; $ca = Get-HAValue $s 'minutes_since_copy'
        $h = 'OK'
        if ($null -eq $ra -or [double]$ra -gt ($thr + $delay)) { $h = 'Critical' } elseif ($null -eq $ca -or [double]$ca -gt $thr) { $h = 'Warning' }
        [pscustomobject][ordered]@{
            Health               = $h
            Database             = $s.secondary_database
            Primary              = "$($s.primary_server).$($s.primary_database)"
            'Min Since Copy'     = $ca
            'Min Since Restore'  = $ra
            'Restore Latency (min)' = $s.last_restored_latency
            'Threshold (min)'    = $thr
            'Restore Delay (min)'= $delay
            Mode                 = $(if ([string]$s.restore_mode -eq '1') { 'STANDBY (readable)' } else { 'NORECOVERY' })
            'DB State'           = $(if (Test-HATrue $s.is_in_standby) { "$($s.state_desc) / STANDBY" } else { $s.state_desc })
            'Copy Job'           = (& $jobTxt $s.copy_job_id)
            'Restore Job'        = (& $jobTxt $s.restore_job_id)
            'Last Restored File' = $s.last_restored_file
        }
    }
    $srvU = $Server.ToUpper()
    $mon = @()
    foreach ($mp in @($Data.MonitorPrimary)) {
        if (([string]$mp.primary_server).ToUpper() -eq $srvU) { continue }
        $thr = Get-HAValue $mp 'backup_threshold' $T.LsDefaultBackupThresholdMin
        $mon += [pscustomobject][ordered]@{ Health = $(if ($null -eq $mp.minutes_since_backup -or [double]$mp.minutes_since_backup -gt [double]$thr) { 'Critical' } else { 'OK' }); Role = 'Primary'; Server = $mp.primary_server; Database = $mp.primary_database; 'Min Since Backup' = $mp.minutes_since_backup; 'Min Since Copy' = $null; 'Min Since Restore' = $null; 'Threshold (min)' = $thr }
    }
    foreach ($ms in @($Data.MonitorSecondary)) {
        if (([string]$ms.secondary_server).ToUpper() -eq $srvU) { continue }
        $thr = Get-HAValue $ms 'restore_threshold' $T.LsDefaultRestoreThresholdMin
        $mon += [pscustomobject][ordered]@{ Health = $(if ($null -eq $ms.minutes_since_restore -or [double]$ms.minutes_since_restore -gt [double]$thr) { 'Critical' } else { 'OK' }); Role = 'Secondary'; Server = $ms.secondary_server; Database = $ms.secondary_database; 'Min Since Backup' = $null; 'Min Since Copy' = $ms.minutes_since_copy; 'Min Since Restore' = $ms.minutes_since_restore; 'Threshold (min)' = $thr }
    }
    $err = foreach ($e in @($Data.Errors)) {
        [pscustomobject][ordered]@{ Health = 'Warning'; Time = $e.log_time; Step = @{ '0' = 'Backup'; '1' = 'Copy'; '2' = 'Restore' }[[string]$e.agent_type]; Database = $e.database_name; Message = $e.message }
    }
    $tables = [ordered]@{}
    $tables['Primary'] = @($pri)
    $tables['Secondary'] = @($sec)
    $tables['Monitor View'] = @($mon)
    $tables['Errors'] = @($err)
    $tables
}

function Get-HALogShippingReport {
    param([Parameter(Mandatory)]$SqlConnection, [Parameter(Mandatory)]$ServerInfo, $Thresholds)
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $r = New-HAFeatureResult -Feature LS
    $server = [string]$ServerInfo.server_name
    $data = Get-HALogShippingData -SqlConnection $SqlConnection -Result $r -Thresholds $Thresholds
    $np = @($data.Primary).Count; $ns = @($data.Secondary).Count
    $srvU = $server.ToUpper()
    $nm = @($data.MonitorPrimary | Where-Object { ([string]$_.primary_server).ToUpper() -ne $srvU }).Count + @($data.MonitorSecondary | Where-Object { ([string]$_.secondary_server).ToUpper() -ne $srvU }).Count
    if ($np + $ns + $nm -eq 0) {
        $r.Summary = 'No log shipping configured on this server.'
        Add-HACollectErrorIssues -Result $r -Server $server
        return $r
    }
    $r.Configured = $true
    $parts = @()
    if ($np) { $r.Roles.Add("LS Primary ($np db)"); $parts += "primary for $np database(s)" }
    if ($ns) { $r.Roles.Add("LS Secondary ($ns db)"); $parts += "secondary for $ns database(s)" }
    if ($nm) { $r.Roles.Add('LS Monitor'); $parts += "monitor for $nm remote database(s)" }
    $r.Summary = 'This server is ' + ($parts -join ', ') + '.'
    foreach ($i in (Get-HALogShippingIssues -Data $data -Server $server -Thresholds $Thresholds -AgentStatus ([string]$ServerInfo.agent_status))) { $r.Issues.Add($i) }
    Add-HACollectErrorIssues -Result $r -Server $server
    $r.Tables = Get-HALogShippingTables -Data $data -Server $server -Thresholds $Thresholds
    $r
}

# ======================= SqlHAMonitor.Replication =======================
<#
    SqlHAMonitor.Replication (transactional, snapshot, merge)
    -------------------------------------------------------
    Roles and what each can see:
      * DISTRIBUTOR : the "post office". Holds every agent's status, history, errors and the backlog of
                      undelivered commands. This is where replication is monitored.
      * PUBLISHER   : source databases. Can show whether the transaction log is held up by replication.
                      Points to the distributor.
      * SUBSCRIBER  : destination databases. Knows which publisher it gets data from and when it last received data.
    The monitor detects each role on the connected server and suggests where to connect next.
#>


$script:RunStatus = @{ '1' = 'Started'; '2' = 'Succeeded (stopped)'; '3' = 'In progress'; '4' = 'Idle'; '5' = 'Retrying'; '6' = 'FAILED' }

function Get-HAReplRunStatusText { param($Code) if ($null -eq $Code) { return 'No history' }; $t = $script:RunStatus[[string]$Code]; if ($t) { $t } else { "Status $Code" } }

function Get-HAReplErrorHint {
    <# Plain-English meaning and the usual fix direction for common replication errors. #>
    param($Code, [string]$Text)
    switch ([string]$Code) {
        '20598' { return @{ Meaning = 'The subscriber is missing a row that the publisher is trying to UPDATE or DELETE. The two copies have drifted apart (someone changed or deleted data directly on the subscriber, or it was not initialised correctly).'; Fix = 'Find the exact command with sp_browsereplcmds, then either insert the missing row at the subscriber, or re-initialize the subscription. Skipping the error (-SkipErrors 20598) lets data drift further - only as an agreed, temporary measure.' } }
        '2627'  { return @{ Meaning = 'The subscriber already has a row with the same key the publisher is trying to INSERT (duplicate key). The copies have drifted apart, often because data was written directly on the subscriber.'; Fix = 'Find the command with sp_browsereplcmds, remove/align the conflicting row at the subscriber, or re-initialize.' } }
        '2601'  { return @{ Meaning = 'Duplicate value in a unique index at the subscriber. The copies have drifted apart.'; Fix = 'Find the command with sp_browsereplcmds, fix the conflicting row at the subscriber, or re-initialize.' } }
        '547'   { return @{ Meaning = 'A foreign key or check constraint at the subscriber rejected the change (for example a child row arrived before its parent, or a constraint exists only at the subscriber).'; Fix = 'Make sure constraints at the subscriber are marked NOT FOR REPLICATION, or fix the missing parent row.' } }
        '18456' { return @{ Meaning = 'Login failed. The account the agent uses cannot log in to the publisher/distributor/subscriber (password changed, account locked or removed).'; Fix = 'Update the agent''s security settings (Replication Monitor or sp_changesubscription / sp_changelogreader_agent) with the correct account, or fix the login.' } }
        '21074' { return @{ Meaning = 'The subscription has been marked inactive: it was not synchronised within the retention period, so the distributor deleted the changes it needed.'; Fix = 'The subscription must be re-initialized (new snapshot or backup). Then find out why the agent was not running for so long.' } }
        '208'   { return @{ Meaning = 'A table or object does not exist at the subscriber (dropped or renamed there).'; Fix = 'Recreate the object at the subscriber or re-initialize the article/subscription.' } }
        '207'   { return @{ Meaning = 'A column does not exist at the subscriber - the table structure differs from the publisher.'; Fix = 'Align the subscriber table schema or re-initialize.' } }
        '8152'  { return @{ Meaning = 'Data would be truncated: a column at the subscriber is smaller than at the publisher.'; Fix = 'Make the subscriber column as large as the publisher column.' } }
        '2628'  { return @{ Meaning = 'Data would be truncated: a column at the subscriber is smaller than at the publisher.'; Fix = 'Make the subscriber column as large as the publisher column.' } }
        '53'    { return @{ Meaning = 'Network path not found: the agent cannot reach the other server (name, DNS, firewall, server down).'; Fix = 'Check the server is up and reachable from the server where the agent runs.' } }
        '-2'    { return @{ Meaning = 'Query timeout: an operation took longer than the agent allows (blocking or a very large transaction).'; Fix = 'Look for blocking at the subscriber/publisher; consider increasing QueryTimeout in the agent profile.' } }
        '1205'  { return @{ Meaning = 'The agent was chosen as a deadlock victim. Usually retries succeed.'; Fix = 'Only act if it repeats; look for application jobs fighting with replication on the same tables.' } }
    }
    $t = [string]$Text
    if ($t -match 'Login failed') { return @{ Meaning = 'Login failed for the account the agent uses.'; Fix = 'Fix the account/password in the agent''s security settings.' } }
    if ($t -match 'Access is denied|access denied') { return @{ Meaning = 'Permission denied on a folder or share (often the snapshot folder).'; Fix = 'Grant the agent''s Windows account read (or for snapshot: write) access to the snapshot share.' } }
    if ($t -match 'not owned by|database owner') { return @{ Meaning = 'The publication database owner is invalid (e.g. an orphaned/removed login), which stops the Log Reader.'; Fix = 'Change the database owner to a valid login (e.g. ALTER AUTHORIZATION ON DATABASE::[db] TO [sa]).' } }
    if ($t -match 'inactive|expired') { return @{ Meaning = 'The subscription is inactive/expired.'; Fix = 'Re-initialize the subscription.' } }
    $null
}

function Get-HAReplicationData {
    param([Parameter(Mandatory)]$SqlConnection, [Parameter(Mandatory)]$Result, $Thresholds)
    $to = $Thresholds.QueryTimeoutSeconds
    $d = @{ Distributors = ([System.Collections.Generic.List[object]]::new()); Subscriptions = ([System.Collections.Generic.List[object]]::new()) }

    $d.Databases = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Replication databases' -Query @"
SELECT  d.name, d.is_published, d.is_merge_published, d.is_distributor, d.is_cdc_enabled, d.log_reuse_wait_desc, d.state_desc
FROM    sys.databases d
WHERE   d.is_published = 1 OR d.is_merge_published = 1 OR d.is_distributor = 1 OR d.log_reuse_wait_desc = N'REPLICATION'
"@
    $d.LogUsed = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Log percent used' -Optional -Query @"
SELECT RTRIM(instance_name) AS name, cntr_value AS log_used_pct
FROM   sys.dm_os_performance_counters
WHERE  counter_name = N'Percent Log Used' AND object_name LIKE N'%:Databases%'
"@
    $d.RemoteDistributor = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Distributor link' -Optional -Query @"
SELECT name, data_source FROM sys.servers WHERE is_distributor = 1
"@

    # ---------- distributor side (one block per distribution database) ----------
    foreach ($db in @($d.Databases | Where-Object { Test-HATrue $_.is_distributor })) {
        $dn = [string]$db.name
        $DQ = ConvertTo-HASqlIdentifier $dn
        $dist = @{ Name = $dn }
        $has = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn metadata" -Optional -Query "SELECT CASE WHEN OBJECT_ID($(ConvertTo-HASqlLiteral "$DQ.dbo.MSreplservers"), N'U') IS NULL THEN 0 ELSE 1 END AS has_replservers"
        $hasRs = ($has.Count -gt 0 -and (Test-HATrue $has[0].has_replservers))
        if ($hasRs) {
            $srvJoin = { param($alias, $col) "LEFT JOIN $DQ.dbo.MSreplservers rs_$alias ON rs_$alias.srvid = a.$col LEFT JOIN sys.servers ss_$alias ON ss_$alias.server_id = a.$col" }
            $srvName = { param($alias) "COALESCE(rs_$alias.srvname, ss_$alias.name)" }
        } else {
            $srvJoin = { param($alias, $col) "LEFT JOIN sys.servers ss_$alias ON ss_$alias.server_id = a.$col" }
            $srvName = { param($alias) "ss_$alias.name" }
        }

        $dist.Distribution = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn distribution agents" -Query @"
SELECT  a.id AS agent_id, a.name AS agent_name, a.job_id, a.local_job, a.publisher_db, a.publication, a.subscriber_db, a.subscription_type,
        $(& $srvName 'p') AS publisher, COALESCE($(& $srvName 's'), a.subscriber_name) AS subscriber,
        h.runstatus, h.[time] AS last_time, DATEDIFF(MINUTE, h.[time], GETDATE()) AS minutes_since_history,
        h.comments, h.delivery_latency, h.current_delivery_latency, h.error_id,
        e.error_code, e.error_text, e.xact_seqno, e.command_id,
        sub.min_status
FROM    $DQ.dbo.MSdistribution_agents a
$(& $srvJoin 'p' 'publisher_id')
$(& $srvJoin 's' 'subscriber_id')
OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.delivery_latency, x.current_delivery_latency, x.error_id
             FROM $DQ.dbo.MSdistribution_history x WITH (NOLOCK)
             WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h
OUTER APPLY (SELECT TOP (1) er.error_code, er.error_text, CONVERT(varchar(42), er.xact_seqno, 1) AS xact_seqno, er.command_id
             FROM $DQ.dbo.MSrepl_errors er WITH (NOLOCK)
             WHERE h.error_id IS NOT NULL AND h.error_id <> 0 AND er.id = h.error_id
             ORDER BY CASE WHEN er.error_code IS NULL OR er.error_code = '' THEN 1 ELSE 0 END, er.[time] DESC) e
OUTER APPLY (SELECT MIN(ms.status) AS min_status FROM $DQ.dbo.MSsubscriptions ms WITH (NOLOCK) WHERE ms.agent_id = a.id) sub
WHERE   a.subscriber_id >= 0
"@

        # Backlog per agent (can be slow on very large distribution dbs, so separate and optional)
        $dist.Pending = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout ([math]::Max($to, 60)) -Label "$dn undelivered commands" -Optional -Query @"
SELECT agent_id, SUM(UndelivCmdsInDistDB) AS pending_cmds
FROM   $DQ.dbo.MSdistribution_status WITH (NOLOCK)
GROUP BY agent_id
"@

        $dist.LogReaders = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn log reader agents" -Query @"
SELECT  a.id AS agent_id, a.name AS agent_name, a.job_id, a.local_job, a.publisher_db,
        $(& $srvName 'p') AS publisher,
        h.runstatus, h.[time] AS last_time, DATEDIFF(MINUTE, h.[time], GETDATE()) AS minutes_since_history,
        h.comments, h.delivery_latency, h.error_id,
        e.error_code, e.error_text
FROM    $DQ.dbo.MSlogreader_agents a
$(& $srvJoin 'p' 'publisher_id')
OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.delivery_latency, x.error_id
             FROM $DQ.dbo.MSlogreader_history x WITH (NOLOCK)
             WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h
OUTER APPLY (SELECT TOP (1) er.error_code, er.error_text FROM $DQ.dbo.MSrepl_errors er WITH (NOLOCK)
             WHERE h.error_id IS NOT NULL AND h.error_id <> 0 AND er.id = h.error_id
             ORDER BY CASE WHEN er.error_code IS NULL OR er.error_code = '' THEN 1 ELSE 0 END, er.[time] DESC) e
"@

        $dist.Snapshots = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn snapshot agents" -Query @"
SELECT  a.id AS agent_id, a.name AS agent_name, a.job_id, a.local_job, a.publisher_db, a.publication, a.publication_type,
        $(& $srvName 'p') AS publisher,
        h.runstatus, h.[time] AS last_time, DATEDIFF(MINUTE, h.[time], GETDATE()) AS minutes_since_history,
        h.comments, h.error_id,
        e.error_code, e.error_text
FROM    $DQ.dbo.MSsnapshot_agents a
$(& $srvJoin 'p' 'publisher_id')
OUTER APPLY (SELECT TOP (1) x.runstatus, x.[time], x.comments, x.error_id
             FROM $DQ.dbo.MSsnapshot_history x WITH (NOLOCK)
             WHERE x.agent_id = a.id ORDER BY x.[time] DESC, x.[timestamp] DESC) h
OUTER APPLY (SELECT TOP (1) er.error_code, er.error_text FROM $DQ.dbo.MSrepl_errors er WITH (NOLOCK)
             WHERE h.error_id IS NOT NULL AND h.error_id <> 0 AND er.id = h.error_id
             ORDER BY CASE WHEN er.error_code IS NULL OR er.error_code = '' THEN 1 ELSE 0 END, er.[time] DESC) e
"@

        $dist.Merge = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn merge agents" -Optional -Query @"
SELECT  a.id AS agent_id, a.name AS agent_name, a.job_id, a.local_job, a.publisher_db, a.publication, a.subscriber_db,
        $(& $srvName 'p') AS publisher, COALESCE($(& $srvName 's'), a.subscriber_name) AS subscriber,
        m.runstatus, m.start_time, m.end_time, DATEDIFF(MINUTE, COALESCE(m.end_time, m.start_time), GETDATE()) AS minutes_since_history,
        m.upload_conflicts, m.download_conflicts, m.percent_complete
FROM    $DQ.dbo.MSmerge_agents a
$(& $srvJoin 'p' 'publisher_id')
$(& $srvJoin 's' 'subscriber_id')
OUTER APPLY (SELECT TOP (1) x.runstatus, x.start_time, x.end_time, x.upload_conflicts, x.download_conflicts, x.percent_complete
             FROM $DQ.dbo.MSmerge_sessions x WITH (NOLOCK)
             WHERE x.agent_id = a.id ORDER BY x.session_id DESC) m
"@

        $dist.Errors = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn recent errors" -Parameters @{ '@h' = [int]$Thresholds.ReplErrorLookbackHours } -Query @"
SELECT TOP (200) e.id, e.[time], e.error_code, e.error_text, e.source_name,
       CONVERT(varchar(42), e.xact_seqno, 1) AS xact_seqno, e.command_id,
       DATEDIFF(MINUTE, e.[time], GETDATE()) AS minutes_ago
FROM   $DQ.dbo.MSrepl_errors e WITH (NOLOCK)
WHERE  e.[time] >= DATEADD(HOUR, -@h, GETDATE())
ORDER BY e.[time] DESC
"@
        $dist.CmdRows = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "$dn size" -Optional -Query @"
SELECT SUM(p.rows) AS cmd_rows
FROM   $DQ.sys.partitions p
WHERE  p.object_id = OBJECT_ID($(ConvertTo-HASqlLiteral "$DQ.dbo.MSrepl_commands")) AND p.index_id IN (0, 1)
"@
        $d.Distributors.Add($dist)
    }

    if ($d.Distributors.Count -gt 0) {
        try { $d.Jobs = Get-HAJobStatus -SqlConnection $SqlConnection -CategoryLike 'REPL-%' }
        catch { $d.Jobs = @(); $Result.Errors.Add([pscustomobject]@{ Label = 'Replication jobs'; Message = $_.Exception.Message; Number = (Get-HASqlErrorNumber $_.Exception); Optional = $false }) }
    } else { $d.Jobs = @() }

    # ---------- subscriber side ----------
    $cands = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Subscriber database scan' -Optional -Query @"
SELECT name FROM sys.databases
WHERE database_id > 4 AND state_desc = N'ONLINE' AND is_distributor = 0 AND HAS_DBACCESS(name) = 1
"@
    if ($cands.Count -gt 0) {
        $probe = ($cands | ForEach-Object {
                $id = ConvertTo-HASqlIdentifier $_.name
                "SELECT $(ConvertTo-HASqlLiteral $_.name) AS db, OBJECT_ID($(ConvertTo-HASqlLiteral "$id.dbo.MSreplication_subscriptions"), N'U') AS oid"
            }) -join "`r`nUNION ALL "
        $found = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label 'Subscriber table probe' -Optional -Query $probe
        foreach ($f in @($found | Where-Object { $null -ne $_.oid })) {
            $id = ConvertTo-HASqlIdentifier $f.db
            $rows = Invoke-HACollect -SqlConnection $SqlConnection -Result $Result -Timeout $to -Label "Subscriptions in $($f.db)" -Optional -Query @"
SELECT $(ConvertTo-HASqlLiteral $f.db) AS subscription_db, s.publisher, s.publisher_db, s.publication, s.subscription_type,
       s.update_mode, s.distribution_agent, s.[time] AS last_sync_time, DATEDIFF(MINUTE, s.[time], GETDATE()) AS minutes_since_sync
FROM   $id.dbo.MSreplication_subscriptions s
"@
            foreach ($r in $rows) { $d.Subscriptions.Add($r) }
        }
    }
    $d.Distributors = $d.Distributors.ToArray()
    $d.Subscriptions = $d.Subscriptions.ToArray()
    $d
}

function New-HAReplAgentIssue {
    <# Issue for a failed/retrying agent, enriched with the error explanation. #>
    param($Agent, [string]$Kind, [string]$Server, [string]$DistDb, [string]$Severity, [string]$Object, [object[]]$ExtraLinks = @(), [string]$ConnectTo, [string]$ConnectReason)
    $code = Get-HAValue $Agent 'error_code' ''
    $text = [string](Get-HAValue $Agent 'error_text' (Get-HAValue $Agent 'comments' ''))
    if ($text.Length -gt 800) { $text = $text.Substring(0, 800) + '...' }
    $hint = Get-HAReplErrorHint -Code $code -Text $text
    $state = Get-HAReplRunStatusText $Agent.runstatus
    $kindPlain = switch ($Kind) {
        'Distribution' { 'The Distribution Agent delivers changes from the distributor to the subscriber.' }
        'LogReader' { 'The Log Reader Agent reads changes from the publisher''s transaction log and stores them at the distributor.' }
        'Snapshot' { 'The Snapshot Agent creates the initial copy (snapshot) of the published tables, used for new or re-initialized subscriptions.' }
        'Merge' { 'The Merge Agent exchanges changes in both directions between publisher and subscriber.' }
    }
    $expl = "$kindPlain It is now: $state."
    if ($code -or $text) { $expl += "`r`nError $($code): $text" }
    if ($hint) { $expl += "`r`n`r`nIn plain words: $($hint.Meaning)" }
    $steps = @()
    if ($hint) { $steps += "Usual fix: $($hint.Fix)" }
    $steps += 'Open Replication Monitor (or the agent job history) to read the full error chain.'
    if ($Kind -eq 'Distribution' -and (Get-HAValue $Agent 'xact_seqno')) { $steps += 'Use sp_browsereplcmds (query below) to see exactly which command failed.' }
    $steps += 'After fixing, restart the agent job and refresh this screen.'

    $DQ = ConvertTo-HASqlIdentifier $DistDb
    $q = @()
    $hist = switch ($Kind) { 'Distribution' { 'MSdistribution_history' } 'LogReader' { 'MSlogreader_history' } 'Snapshot' { 'MSsnapshot_history' } 'Merge' { 'MSmerge_sessions' } }
    if ($Kind -ne 'Merge') {
        $q += New-HAQuerySuggestion -RunOn "Distributor: $Server ($DistDb)" -Title 'Recent agent history' -Sql "SELECT TOP (30) h.[time], h.runstatus, h.comments, h.error_id`r`nFROM $DQ.dbo.$hist h WHERE h.agent_id = $([int]$Agent.agent_id) ORDER BY h.[time] DESC;"
    } else {
        $q += New-HAQuerySuggestion -RunOn "Distributor: $Server ($DistDb)" -Title 'Recent merge sessions' -Sql "SELECT TOP (20) session_id, start_time, end_time, runstatus, upload_conflicts, download_conflicts`r`nFROM $DQ.dbo.MSmerge_sessions WHERE agent_id = $([int]$Agent.agent_id) ORDER BY session_id DESC;"
    }
    $eid = Get-HAValue $Agent 'error_id'
    if ($eid) { $q += New-HAQuerySuggestion -RunOn "Distributor: $Server ($DistDb)" -Title 'Full error chain' -Sql "SELECT [time], error_code, error_text, source_name, xact_seqno, command_id FROM $DQ.dbo.MSrepl_errors WHERE id = $([int]$eid) ORDER BY [time];" }
    $xs = Get-HAValue $Agent 'xact_seqno'
    if ($Kind -eq 'Distribution' -and $xs) {
        $cmdId = Get-HAValue $Agent 'command_id'
        $q += New-HAQuerySuggestion -RunOn "Distributor: $Server ($DistDb)" -Title 'Show the failing command (read-only browse)' -Sql "USE $DQ;`r`nEXEC sp_browsereplcmds @xact_seqno_start = '$xs', @xact_seqno_end = '$xs'$(if ($cmdId) { ", @command_id = $([int]$cmdId)" }), @publisher_database_id = (SELECT TOP (1) publisher_database_id FROM dbo.MSdistribution_agents WHERE id = $([int]$Agent.agent_id));"
    }
    if ($Kind -eq 'Distribution' -and [string]$code -eq '21074') {
        $q += New-HAQuerySuggestion -Kind Fix -RunOn "Publisher: $($Agent.publisher) ($($Agent.publisher_db))" -Title 'Mark the push subscription for re-initialization' -Sql "USE $(ConvertTo-HASqlIdentifier $Agent.publisher_db);`r`nEXEC sp_reinitsubscription @publication = $(ConvertTo-HASqlLiteral $Agent.publication), @subscriber = $(ConvertTo-HASqlLiteral $Agent.subscriber), @destination_db = $(ConvertTo-HASqlLiteral $Agent.subscriber_db);"
    }
    if ($Kind -eq 'Distribution' -and @('20598', '2627', '2601') -contains [string]$code) {
        $q += New-HAQuerySuggestion -Kind Fix -RunOn "Distributor: $Server ($DistDb)" -Title 'LAST RESORT: skip data-consistency errors (data will differ!)' -Sql "-- Creates/uses an agent profile that skips these errors. Agree with the data owner first and plan a re-sync.`r`n-- In Replication Monitor: Agent Profile > 'Continue on data consistency errors', then restart the agent."
    }
    $links = @((Get-HALink ReplTroubleshoot 'Microsoft: Troubleshoot transactional replication errors')) + $ExtraLinks
    if ($Kind -eq 'Distribution') { $links += Get-HALink ReplBrowseCmds 'Microsoft: sp_browsereplcmds'; $links += Get-HALink ReplReinit 'Microsoft: Reinitialize a subscription' }
    New-HAIssue -Severity $Severity -Feature REPL -Server $Server -Object $Object -Title "$Kind Agent $state - $Object" -Explanation $expl `
        -Impact $(switch ($Kind) { 'Distribution' { 'The subscriber is not getting new changes; it falls further behind until this is fixed.' } 'LogReader' { 'No new changes leave the publisher for ANY subscriber of this database, and the publisher''s transaction log cannot be cleared (it will grow).' } 'Snapshot' { 'New or re-initialized subscriptions cannot be set up. Existing subscriptions keep working.' } 'Merge' { 'Changes are not being exchanged with this subscriber.' } }) `
        -Steps $steps -Queries $q -Links $links -ConnectTo $ConnectTo -ConnectReason $ConnectReason
}

function Get-HAReplicationIssues {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Server, $Thresholds, [string]$AgentStatus = 'Unknown')
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $T = $Thresholds
    $issues = ([System.Collections.Generic.List[object]]::new())
    $lnkT = Get-HALink ReplTroubleshoot 'Microsoft: Troubleshoot transactional replication errors'
    $lnkL = Get-HALink ReplLatency 'Microsoft: Measure latency with tracer tokens'
    $lnkA = Get-HALink ReplAgentAdmin 'Microsoft: Replication maintenance jobs'
    $srvU = $Server.ToUpper()

    $jobs = @{}; foreach ($j in @($Data.Jobs)) { $jobs[([string]$j.job_id).ToLower()] = $j }
    $isDistributor = (@($Data.Distributors).Count -gt 0)

    if ($isDistributor -and $AgentStatus -match 'Stop') {
        $issues.Add((New-HAAgentStoppedIssue -Server $Server -Feature REPL -Why 'Replication agents and cleanup jobs on this distributor are SQL Agent jobs - none of them run while Agent is stopped.'))
    }

    foreach ($dist in @($Data.Distributors)) {
        $dn = $dist.Name
        $DQ = ConvertTo-HASqlIdentifier $dn
        $pending = @{}; foreach ($p in @($dist.Pending)) { $pending[[string]$p.agent_id] = $p.pending_cmds }

        # ---- Log Readers ----
        foreach ($a in @($dist.LogReaders)) {
            $obj = "$($a.publisher).$($a.publisher_db)"
            $rs = [string](Get-HAValue $a 'runstatus' '')
            $pubRemote = ([string]$a.publisher).ToUpper() -ne $srvU
            $ct = if ($pubRemote) { [string]$a.publisher } else { '' }
            if ($rs -eq '6') { $issues.Add((New-HAReplAgentIssue -Agent $a -Kind LogReader -Server $Server -DistDb $dn -Severity Critical -Object $obj -ConnectTo $ct -ConnectReason 'Check the publisher log usage / database owner')) }
            elseif ($rs -eq '5') { $issues.Add((New-HAReplAgentIssue -Agent $a -Kind LogReader -Server $Server -DistDb $dn -Severity Warning -Object $obj)) }
            elseif ($rs -eq '2') {
                $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $obj -Title "Log Reader for $obj is STOPPED" `
                            -Explanation 'The Log Reader normally runs all the time. It last reported that it stopped, so changes made in the published database are not being picked up.' `
                            -Impact 'No new changes reach any subscriber of this database, and the publisher''s transaction log cannot be cleared - it will grow.' `
                            -Steps @('Start the Log Reader Agent job (Replication Monitor > Agents, or the job below).', 'If it stops again, read its history for the error.') `
                            -Queries @((New-HAQuerySuggestion -RunOn "Distributor: $Server" -Title 'Log reader job name' -Sql "SELECT a.name AS agent_name, j.name AS job_name, j.enabled FROM $DQ.dbo.MSlogreader_agents a LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE a.id = $([int]$a.agent_id);")) `
                            -Links @($lnkT)))
            } elseif ($rs -eq '') {
                $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $obj -Title "Log Reader for $obj has no history" -Explanation 'The Log Reader Agent has never recorded any activity (or history was cleaned up while it was not running).' -Impact 'Changes may not be flowing.' -Steps @('Check the Log Reader job exists and is running.') -Links @($lnkT)))
            } else {
                $age = Get-HAValue $a 'minutes_since_history'
                if ($null -ne $age -and [double]$age -gt $T.ReplAgentStaleMinutes) {
                    $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $obj -Title "Log Reader for $obj has not reported for $(Format-HAMinutes $age)" `
                                -Explanation 'The agent says it is running, but it has not written any status for a long time. It may be hung, or stuck reading a very large transaction.' `
                                -Impact 'Changes may be delayed for all subscribers of this database.' `
                                -Steps @('Check for a large open transaction on the publisher (DBCC OPENTRAN).', 'Restart the Log Reader job if it is hung.') `
                                -Queries @((New-HAQuerySuggestion -RunOn "Publisher: $($a.publisher)" -Title 'Oldest open / replicated transaction' -Sql "USE $(ConvertTo-HASqlIdentifier $a.publisher_db);`r`nDBCC OPENTRAN;")) -Links @($lnkT)))
                }
                $lat = Get-HAValue $a 'delivery_latency'
                if ($null -ne $lat) {
                    $sec = [double]$lat / 1000
                    if ($sec -ge $T.ReplLatencyCritSeconds) { $sev = 'Critical' } elseif ($sec -ge $T.ReplLatencyWarnSeconds) { $sev = 'Warning' } else { $sev = $null }
                    if ($sev) {
                        $issues.Add((New-HAIssue -Severity $sev -Feature REPL -Server $Server -Object $obj -Title "Log Reader latency $([math]::Round($sec)) s for $obj" `
                                    -Explanation "Changes are reaching the distributor about $([math]::Round($sec)) seconds after they happen on the publisher. Usually caused by a very large transaction (big update/delete, index rebuild with many changes) or a slow/busy publisher log." `
                                    -Impact 'All subscribers of this database receive data late.' `
                                    -Steps @('Check for large batch jobs on the publisher.', 'Post a tracer token to measure end-to-end latency (query below).') `
                                    -Queries @((New-HAQuerySuggestion -Kind Fix -RunOn "Publisher: $($a.publisher)" -Title 'Post a tracer token (writes a tiny marker - safe, but it is a write)' -Sql "USE $(ConvertTo-HASqlIdentifier $a.publisher_db);`r`nDECLARE @id int;`r`nEXEC sys.sp_posttracertoken @publication = N'<publication name>', @tracer_token_id = @id OUTPUT;`r`n-- later: EXEC sys.sp_helptracertokenhistory @publication = N'<publication name>', @tracer_id = @id;")) `
                                    -Links @($lnkL)))
                    }
                }
            }
            if ($pubRemote) {
                # nothing else - publisher log is checked when connected to the publisher
            }
        }

        # ---- Distribution agents ----
        foreach ($a in @($dist.Distribution)) {
            $obj = "$($a.publication) -> $($a.subscriber).$($a.subscriber_db)"
            $rs = [string](Get-HAValue $a 'runstatus' '')
            $pcmd = $pending[[string]$a.agent_id]
            $isPull = ([string]$a.subscription_type -eq '1')
            $ms = Get-HAValue $a 'min_status'

            if ($null -ne $ms -and [string]$ms -eq '0') {
                $issues.Add((New-HAIssue -Severity Critical -Feature REPL -Server $Server -Object $obj -Title "Subscription is INACTIVE: $obj" `
                            -Explanation 'The subscription has been deactivated - usually because it did not synchronise within the retention period, so the changes it needed have been cleaned up.' `
                            -Impact 'The subscriber gets no changes at all. It must be re-initialized (fresh snapshot or backup) to recover.' `
                            -Steps @('Re-initialize the subscription (query below) and run the Snapshot Agent if a new snapshot is needed.', 'Find out why the Distribution Agent did not run for so long (job disabled? subscriber offline?).') `
                            -Queries @((New-HAQuerySuggestion -Kind Fix -RunOn "Publisher: $($a.publisher) ($($a.publisher_db))" -Title $(if ($isPull) { 'Re-initialize (pull subscription - run at the SUBSCRIBER instead with sp_reinitpullsubscription)' } else { 'Re-initialize push subscription' }) `
                                    -Sql $(if ($isPull) { "-- At subscriber $($a.subscriber), database $($a.subscriber_db):`r`nEXEC sp_reinitpullsubscription @publisher = $(ConvertTo-HASqlLiteral $a.publisher), @publisher_db = $(ConvertTo-HASqlLiteral $a.publisher_db), @publication = $(ConvertTo-HASqlLiteral $a.publication);" } else { "USE $(ConvertTo-HASqlIdentifier $a.publisher_db);`r`nEXEC sp_reinitsubscription @publication = $(ConvertTo-HASqlLiteral $a.publication), @subscriber = $(ConvertTo-HASqlLiteral $a.subscriber), @destination_db = $(ConvertTo-HASqlLiteral $a.subscriber_db);" }))) `
                            -Links @((Get-HALink ReplReinit 'Microsoft: Reinitialize a subscription'), $lnkT)))
                continue
            }

            $ct = ''; $cr = ''
            if ($isPull) { $ct = [string]$a.subscriber; $cr = 'Pull subscription - the agent job runs on the subscriber' }

            if ($rs -eq '6') { $issues.Add((New-HAReplAgentIssue -Agent $a -Kind Distribution -Server $Server -DistDb $dn -Severity Critical -Object $obj -ConnectTo $ct -ConnectReason $cr)); continue }
            if ($rs -eq '5') { $issues.Add((New-HAReplAgentIssue -Agent $a -Kind Distribution -Server $Server -DistDb $dn -Severity Warning -Object $obj -ConnectTo $ct -ConnectReason $cr)); continue }
            if ($rs -eq '') {
                $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $obj -Title "Distribution Agent has no history: $obj" `
                            -Explanation 'This subscription''s delivery agent has never recorded any activity. It may never have been started, or (for a pull subscription) it runs on the subscriber and cannot log here.' `
                            -Impact 'The subscriber may not be receiving data.' -Steps @('Check the agent job exists and is running (on the subscriber for pull subscriptions).') -Links @($lnkT) -ConnectTo $ct -ConnectReason $cr))
                continue
            }

            $age = Get-HAValue $a 'minutes_since_history'
            if (@('1', '3', '4') -contains $rs -and $null -ne $age -and [double]$age -gt $T.ReplAgentStaleMinutes) {
                $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $obj -Title "Distribution Agent silent for $(Format-HAMinutes $age): $obj" `
                            -Explanation 'The agent says it is running but has not reported anything for a long time. It may be hung or stuck applying a very large transaction at the subscriber (often blocked there).' `
                            -Impact 'Delivery to this subscriber may be stalled.' `
                            -Steps @("Check for blocking on the subscriber $($a.subscriber) in database $($a.subscriber_db).", 'Restart the Distribution Agent job if it is hung.') `
                            -Queries @((New-HAQuerySuggestion -RunOn "Subscriber: $($a.subscriber)" -Title 'Blocking at the subscriber' -Sql "SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time, s.program_name, DB_NAME(r.database_id) AS db`r`nFROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE r.blocking_session_id <> 0;")) `
                            -Links @($lnkT) -ConnectTo ([string]$a.subscriber) -ConnectReason 'Look for blocking at the subscriber'))
            }

            if ($null -ne $pcmd) {
                $sev = $null
                if ([double]$pcmd -ge $T.ReplPendingCmdsCrit) { $sev = 'Critical' } elseif ([double]$pcmd -ge $T.ReplPendingCmdsWarn) { $sev = 'Warning' }
                if ($sev) {
                    $stoppedTxt = if ($rs -eq '2') { ' The agent is currently STOPPED (it may run on a schedule rather than continuously).' } else { '' }
                    $issues.Add((New-HAIssue -Severity $sev -Feature REPL -Server $Server -Object $obj -Title ("{0:N0} commands waiting for {1}" -f [double]$pcmd, $obj) `
                                -Explanation ("There are {0:N0} changes stored at the distributor that have not yet been delivered to this subscriber.{1} Think of it as an inbox that is filling up faster than it is emptied." -f [double]$pcmd, $stoppedTxt) `
                                -Impact 'The subscriber is behind by that many changes. A very large backlog also makes the distribution database grow and can push the subscription towards expiry.' `
                                -Steps @(
                                    'If a big batch ran on the publisher (mass update/delete), the backlog may just need time - watch the trend with auto-refresh.',
                                    'Check the subscriber for blocking or slow disks.',
                                    'Make sure the agent is running continuously (or more often) if it is scheduled.'
                                ) `
                                -Queries @(
                                    (New-HAQuerySuggestion -RunOn "Distributor: $Server ($dn)" -Title 'Pending vs delivered commands per article' -Sql "SELECT s.article_id, s.UndelivCmdsInDistDB, s.DelivCmdsInDistDB FROM $DQ.dbo.MSdistribution_status s WHERE s.agent_id = $([int]$a.agent_id) ORDER BY s.UndelivCmdsInDistDB DESC;"),
                                    (New-HAQuerySuggestion -RunOn "Distributor: $Server ($dn)" -Title 'Recent delivery rate and latency' -Sql "SELECT TOP (20) [time], runstatus, delivery_rate, delivery_latency, current_delivery_latency, comments FROM $DQ.dbo.MSdistribution_history WHERE agent_id = $([int]$a.agent_id) ORDER BY [time] DESC;")
                                ) -Links @($lnkL, $lnkT)))
                }
            }

            if (@('3', '4') -contains $rs) {
                $latMs = Get-HAValue $a 'current_delivery_latency' (Get-HAValue $a 'delivery_latency')
                if ($null -ne $latMs) {
                    $sec = [double]$latMs / 1000
                    $sev = $null
                    if ($sec -ge $T.ReplLatencyCritSeconds) { $sev = 'Critical' } elseif ($sec -ge $T.ReplLatencyWarnSeconds) { $sev = 'Warning' }
                    if ($sev) {
                        $issues.Add((New-HAIssue -Severity $sev -Feature REPL -Server $Server -Object $obj -Title "Delivery latency $([math]::Round($sec)) s: $obj" `
                                    -Explanation "Changes are arriving at the subscriber about $([math]::Round($sec)) seconds after they reached the distributor." `
                                    -Impact 'Reports/applications reading the subscriber see slightly old data.' `
                                    -Steps @('Use a tracer token to see whether the delay is publisher->distributor or distributor->subscriber.', 'Check blocking and disk speed at the subscriber.') `
                                    -Links @($lnkL)))
                    }
                }
            }

            # agent job disabled (push, local job)
            if ($a.job_id -and (Test-HATrue $a.local_job)) {
                $j = $jobs[([string]$a.job_id).ToLower()]
                if ($j -and -not (Test-HATrue $j.enabled)) { $ji = New-HAJobIssue -Job $j -Feature REPL -Server $Server -Purpose "Distribution Agent job for $obj" -WhatItDoes 'It delivers changes to the subscriber.' -Links @($lnkT); if ($ji) { $issues.Add($ji) } }
            }
        }

        # ---- Snapshot agents ----
        foreach ($a in @($dist.Snapshots)) {
            if ([string](Get-HAValue $a 'runstatus' '') -eq '6') {
                $issues.Add((New-HAReplAgentIssue -Agent $a -Kind Snapshot -Server $Server -DistDb $dn -Severity Warning -Object "$($a.publisher).$($a.publisher_db) / $($a.publication)"))
            }
        }

        # ---- Merge agents ----
        foreach ($a in @($dist.Merge)) {
            $obj = "$($a.publication) <-> $($a.subscriber).$($a.subscriber_db)"
            $rs = [string](Get-HAValue $a 'runstatus' '')
            if ($rs -eq '6') { $issues.Add((New-HAReplAgentIssue -Agent $a -Kind Merge -Server $Server -DistDb $dn -Severity Critical -Object $obj)) }
            elseif ($rs -eq '5') { $issues.Add((New-HAReplAgentIssue -Agent $a -Kind Merge -Server $Server -DistDb $dn -Severity Warning -Object $obj)) }
            $conf = [double](Get-HAValue $a 'upload_conflicts' 0) + [double](Get-HAValue $a 'download_conflicts' 0)
            if ($conf -gt 0) {
                $issues.Add((New-HAIssue -Severity Info -Feature REPL -Server $Server -Object $obj -Title "$conf merge conflict(s) in the last session: $obj" `
                            -Explanation 'The same row was changed on both sides; merge replication picked a winner automatically based on the conflict rules.' `
                            -Impact 'Data is consistent, but one side''s change was overwritten. Business owners may need to review.' `
                            -Steps @('Review conflicts in SSMS: right-click the publication > View Conflicts.')))
            }
        }

        # ---- cleanup / maintenance jobs ----
        foreach ($j in @($Data.Jobs | Where-Object { @('REPL-Distribution Cleanup', 'REPL-History Cleanup', 'REPL-Subscription Cleanup', 'REPL-Checkup') -contains [string]$_.category })) {
            $ji = New-HAJobIssue -Job $j -Feature REPL -Server $Server -Purpose "replication maintenance job ($($j.category))" -WhatItDoes 'Maintenance jobs remove delivered commands and old history from the distribution database.' -Links @($lnkA)
            # Distribution / history cleanup matter most; expired-subscription cleanup and checkup are lower priority
            if ($ji) { $ji.Severity = $(if (@('REPL-Distribution Cleanup', 'REPL-History Cleanup') -contains [string]$j.category) { 'Warning' } else { 'Info' }); $ji.Impact = 'If cleanup does not run, the distribution database keeps growing and replication gets slower over time.'; $issues.Add($ji) }
        }

        # ---- size ----
        $cr = @($dist.CmdRows)
        if ($cr.Count -gt 0 -and $null -ne $cr[0].cmd_rows) {
            $n = [double]$cr[0].cmd_rows
            if ($n -ge 50000000) {
                $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object "$dn" -Title ("Distribution database holds {0:N0} commands" -f $n) `
                            -Explanation 'The distribution database is very large. Delivered commands should be removed by the "Distribution clean up" job; a huge number means cleanup is behind, retention is long, or some subscription is far behind and holding everything.' `
                            -Impact 'Replication slows down (agents and cleanup take longer), and disk usage grows.' `
                            -Steps @('Check the Distribution clean up job succeeds and how long it takes.', 'Look for subscriptions that are far behind or inactive (they keep old commands alive).') `
                            -Links @($lnkA)))
            }
        }
    }

    # ---- publisher side ----
    $logPct = @{}; foreach ($l in @($Data.LogUsed)) { $logPct[[string]$l.name] = $l.log_used_pct }
    $remoteDist = @($Data.RemoteDistributor | Where-Object { $_.data_source -and ([string]$_.data_source).ToUpper() -ne $srvU }) | Select-Object -First 1
    $pubs = @($Data.Databases | Where-Object { (Test-HATrue $_.is_published) -or (Test-HATrue $_.is_merge_published) })
    foreach ($db in @($Data.Databases | Where-Object { [string]$_.log_reuse_wait_desc -eq 'REPLICATION' })) {
        $name = [string]$db.name
        $pct = $logPct[$name]
        $published = (Test-HATrue $db.is_published) -or (Test-HATrue $db.is_merge_published)
        if (-not $published -and -not (Test-HATrue $db.is_cdc_enabled)) {
            $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $name -Title "$name log is held by REPLICATION, but the database is not published" `
                        -Explanation 'The transaction log of this database cannot be cleared because SQL Server thinks replication still needs it - but the database is not published (and Change Data Capture is off). This is usually a leftover from replication that was removed incompletely, or a database restored from a published one.' `
                        -Impact "The log file keeps growing$(if ($null -ne $pct) { " (currently $pct% used)" }) until the disk fills." `
                        -Steps @('Confirm with the team the database really should not be replicated.', 'The usual fix is sp_removedbreplication (or sp_repldone) - these are DBA actions; read the docs first.') `
                        -Queries @(
                            (New-HAQuerySuggestion -RunOn $Server -Title 'Confirm the state' -Sql "SELECT name, is_published, is_merge_published, is_cdc_enabled, log_reuse_wait_desc FROM sys.databases WHERE name = $(ConvertTo-HASqlLiteral $name);"),
                            (New-HAQuerySuggestion -Kind Fix -RunOn $Server -Title 'Remove leftover replication metadata (DBA only)' -Sql "EXEC sp_removedbreplication @dbname = $(ConvertTo-HASqlLiteral $name);")
                        ) -Links @($lnkT)))
            continue
        }
        if ($null -ne $pct) {
            $sev = $null
            if ([double]$pct -ge $T.ReplLogUsedCritPct) { $sev = 'Critical' } elseif ([double]$pct -ge $T.ReplLogUsedWarnPct) { $sev = 'Warning' }
            if ($sev) {
                $ct = ''; if ($remoteDist) { $ct = [string]$remoteDist.data_source }
                $issues.Add((New-HAIssue -Severity $sev -Feature REPL -Server $Server -Object $name -Title "$name log is $pct% full and waiting on REPLICATION" `
                            -Explanation 'The publisher''s transaction log cannot be cleared because the Log Reader Agent has not yet read all changes from it. Either the Log Reader is stopped/failing, or it is far behind (large transactions).' `
                            -Impact 'If the log fills completely, the database stops accepting changes - an outage for applications.' `
                            -Steps @(
                                $(if ($ct) { "Connect to the distributor $ct and check the Log Reader Agent for this database." } else { 'Check the Log Reader Agent for this database in the Agents grid / Replication Monitor.' }),
                                'Check for a very large or long-running transaction (DBCC OPENTRAN).',
                                'If the log is close to full, the DBA may need to add log space temporarily while the Log Reader catches up.'
                            ) `
                            -Queries @((New-HAQuerySuggestion -RunOn "Publisher: $Server" -Title 'Oldest replicated transaction not yet read' -Sql "USE $(ConvertTo-HASqlIdentifier $name);`r`nDBCC OPENTRAN;"), (New-HAQuerySuggestion -RunOn "Publisher: $Server" -Title 'Log size and use' -Sql "USE $(ConvertTo-HASqlIdentifier $name);`r`nSELECT total_log_size_in_bytes/1048576 AS log_mb, used_log_space_in_percent FROM sys.dm_db_log_space_usage;")) `
                            -Links @($lnkT) -ConnectTo $ct -ConnectReason 'The Log Reader status is on the distributor'))
            }
        }
    }
    if ($pubs.Count -gt 0 -and $remoteDist) {
        $issues.Add((New-HAIssue -Severity Info -Feature REPL -Server $Server -Object 'Publisher' `
                    -Title "This publisher uses remote distributor $($remoteDist.data_source)" `
                    -Explanation "Published database(s) here: $(($pubs | ForEach-Object { $_.name }) -join ', '). Agent status, backlog and errors are kept on the distributor $($remoteDist.data_source); this server can only show whether its transaction logs are held up by replication." `
                    -Impact 'Not a problem - connect to the distributor for the full picture.' `
                    -ConnectTo ([string]$remoteDist.data_source) -ConnectReason 'Distributor - all agent status lives there'))
    }

    # ---- subscriber side ----
    foreach ($s in @($Data.Subscriptions)) {
        $obj = "$($s.subscription_db) <- $($s.publisher).$($s.publisher_db) / $($s.publication)"
        $age = Get-HAValue $s 'minutes_since_sync'
        $ct = [string]$s.publisher
        if ($null -ne $age -and [double]$age -gt $T.ReplSubscriberStaleMin) {
            $issues.Add((New-HAIssue -Severity Warning -Feature REPL -Server $Server -Object $obj -Title "Subscriber $($s.subscription_db) last received data $(Format-HAMinutes $age) ago" `
                        -Explanation "This database is a replication subscriber of $($s.publisher). The delivery agent last updated it $(Format-HAMinutes $age) ago. This can be normal if nothing changed at the publisher - or it can mean the agent is stopped/failing." `
                        -Impact 'If changes are happening at the publisher, this copy is out of date.' `
                        -Steps @("Check the Distribution Agent at the distributor (connect to the publisher $($s.publisher) - the monitor will point to its distributor if it is a different server).", 'Ask whether data changed at the publisher in that period.') `
                        -Queries @((New-HAQuerySuggestion -RunOn "Subscriber: $Server" -Title 'Subscription details' -Sql "SELECT publisher, publisher_db, publication, distribution_agent, [time] AS last_update FROM $(ConvertTo-HASqlIdentifier $s.subscription_db).dbo.MSreplication_subscriptions;")) `
                        -Links @($lnkT) -ConnectTo $ct -ConnectReason 'Publisher (leads to the distributor)'))
        } else {
            $issues.Add((New-HAIssue -Severity Info -Feature REPL -Server $Server -Object $obj -Title "$($s.subscription_db) subscribes to $($s.publication) on $($s.publisher)" `
                        -Explanation "Last data received $(Format-HAMinutes $age) ago. Agent status and backlog are on the distributor." `
                        -ConnectTo $ct -ConnectReason 'Publisher (leads to the distributor)'))
        }
    }
    , $issues.ToArray()
}

function Get-HAReplicationTables {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Server, $Thresholds)
    $T = $Thresholds
    $healthOf = {
        param($rs, $age)
        switch ([string]$rs) { '6' { 'Critical' } '5' { 'Warning' } '' { 'Warning' } default { if (@('1', '3', '4') -contains [string]$rs -and $null -ne $age -and [double]$age -gt $T.ReplAgentStaleMinutes) { 'Warning' } else { 'OK' } } }
    }
    $agents = @()
    foreach ($dist in @($Data.Distributors)) {
        $pending = @{}; foreach ($p in @($dist.Pending)) { $pending[[string]$p.agent_id] = $p.pending_cmds }
        foreach ($a in @($dist.LogReaders)) {
            $agents += [pscustomobject][ordered]@{ Health = (& $healthOf $a.runstatus $a.minutes_since_history); Type = 'Log Reader'; Publisher = $a.publisher; 'Pub DB' = $a.publisher_db; Publication = '(all)'; Subscriber = ''; 'Sub DB' = ''; Status = (Get-HAReplRunStatusText $a.runstatus); 'Min Since Update' = $a.minutes_since_history; 'Latency (s)' = $(if ($null -ne $a.delivery_latency) { [math]::Round([double]$a.delivery_latency / 1000, 1) }); 'Pending Cmds' = $null; 'Last Message' = $a.comments; 'Distribution DB' = $dist.Name }
        }
        foreach ($a in @($dist.Distribution)) {
            $h = & $healthOf $a.runstatus $a.minutes_since_history
            $pc = $pending[[string]$a.agent_id]
            if ($null -ne $pc -and [double]$pc -ge $T.ReplPendingCmdsCrit) { $h = 'Critical' } elseif ($null -ne $pc -and [double]$pc -ge $T.ReplPendingCmdsWarn -and $h -eq 'OK') { $h = 'Warning' }
            if ($null -ne $a.min_status -and [string]$a.min_status -eq '0') { $h = 'Critical' }
            $lat = if ($null -ne $a.current_delivery_latency) { $a.current_delivery_latency } else { $a.delivery_latency }
            $agents += [pscustomobject][ordered]@{ Health = $h; Type = $(if ([string]$a.subscription_type -eq '1') { 'Distribution (pull)' } else { 'Distribution (push)' }); Publisher = $a.publisher; 'Pub DB' = $a.publisher_db; Publication = $a.publication; Subscriber = $a.subscriber; 'Sub DB' = $a.subscriber_db; Status = $(if ($null -ne $a.min_status -and [string]$a.min_status -eq '0') { 'SUBSCRIPTION INACTIVE' } else { Get-HAReplRunStatusText $a.runstatus }); 'Min Since Update' = $a.minutes_since_history; 'Latency (s)' = $(if ($null -ne $lat) { [math]::Round([double]$lat / 1000, 1) }); 'Pending Cmds' = $pc; 'Last Message' = $a.comments; 'Distribution DB' = $dist.Name }
        }
        foreach ($a in @($dist.Snapshots)) {
            $agents += [pscustomobject][ordered]@{ Health = $(if ([string]$a.runstatus -eq '6') { 'Warning' } else { 'OK' }); Type = 'Snapshot'; Publisher = $a.publisher; 'Pub DB' = $a.publisher_db; Publication = $a.publication; Subscriber = ''; 'Sub DB' = ''; Status = (Get-HAReplRunStatusText $a.runstatus); 'Min Since Update' = $a.minutes_since_history; 'Latency (s)' = $null; 'Pending Cmds' = $null; 'Last Message' = $a.comments; 'Distribution DB' = $dist.Name }
        }
        foreach ($a in @($dist.Merge)) {
            $agents += [pscustomobject][ordered]@{ Health = $(switch ([string]$a.runstatus) { '6' { 'Critical' } '5' { 'Warning' } default { 'OK' } }); Type = 'Merge'; Publisher = $a.publisher; 'Pub DB' = $a.publisher_db; Publication = $a.publication; Subscriber = $a.subscriber; 'Sub DB' = $a.subscriber_db; Status = (Get-HAReplRunStatusText $a.runstatus); 'Min Since Update' = $a.minutes_since_history; 'Latency (s)' = $null; 'Pending Cmds' = $null; 'Last Message' = "Conflicts up/down: $($a.upload_conflicts)/$($a.download_conflicts)"; 'Distribution DB' = $dist.Name }
        }
    }
    $logPct = @{}; foreach ($l in @($Data.LogUsed)) { $logPct[[string]$l.name] = $l.log_used_pct }
    $pubRows = foreach ($db in @($Data.Databases)) {
        $pct = $logPct[[string]$db.name]
        $role = @(); if (Test-HATrue $db.is_published) { $role += 'Transactional/Snapshot publisher' }; if (Test-HATrue $db.is_merge_published) { $role += 'Merge publisher' }; if (Test-HATrue $db.is_distributor) { $role += 'Distribution DB' }
        $h = 'OK'
        if ([string]$db.log_reuse_wait_desc -eq 'REPLICATION' -and $null -ne $pct) { if ([double]$pct -ge $T.ReplLogUsedCritPct) { $h = 'Critical' } elseif ([double]$pct -ge $T.ReplLogUsedWarnPct) { $h = 'Warning' } }
        [pscustomobject][ordered]@{ Health = $h; Database = $db.name; Role = ($role -join ', '); 'Log Reuse Wait' = $db.log_reuse_wait_desc; 'Log Used %' = $pct; State = $db.state_desc }
    }
    $subRows = foreach ($s in @($Data.Subscriptions)) {
        [pscustomobject][ordered]@{ Health = $(if ($null -ne $s.minutes_since_sync -and [double]$s.minutes_since_sync -gt $T.ReplSubscriberStaleMin) { 'Warning' } else { 'OK' }); 'Subscription DB' = $s.subscription_db; Publisher = $s.publisher; 'Pub DB' = $s.publisher_db; Publication = $s.publication; Type = $(if ([string]$s.subscription_type -eq '1') { 'Pull' } elseif ([string]$s.subscription_type -eq '0') { 'Push' } else { 'Anonymous' }); 'Last Sync' = $s.last_sync_time; 'Min Since Sync' = $s.minutes_since_sync }
    }
    $errRows = @()
    foreach ($dist in @($Data.Distributors)) {
        foreach ($e in @($dist.Errors)) { $errRows += [pscustomobject][ordered]@{ Health = 'Warning'; Time = $e.time; Code = $e.error_code; Source = $e.source_name; Message = $e.error_text; 'xact_seqno' = $e.xact_seqno; 'Distribution DB' = $dist.Name } }
    }
    $jobRows = foreach ($j in @($Data.Jobs)) {
        [pscustomobject][ordered]@{ Health = $(if (-not (Test-HATrue $j.enabled)) { 'Warning' } elseif ([string]$j.run_status -eq '0') { 'Warning' } else { 'OK' }); Job = $j.job_name; Category = $j.category; Enabled = $(if (Test-HATrue $j.enabled) { 'Yes' } else { 'NO' }); 'Last Outcome' = (Get-HAJobOutcomeText $j); 'Last Run' = $j.run_datetime }
    }
    $tables = [ordered]@{}
    $tables['Agents'] = @($agents)
    $tables['Publisher DBs'] = @($pubRows)
    $tables['Subscriber View'] = @($subRows)
    $tables['Errors'] = @($errRows)
    $tables['Jobs'] = @($jobRows)
    $tables
}

function Get-HAReplicationReport {
    param([Parameter(Mandatory)]$SqlConnection, [Parameter(Mandatory)]$ServerInfo, $Thresholds)
    if (-not $Thresholds) { $Thresholds = Get-HADefaultThresholds }
    $r = New-HAFeatureResult -Feature REPL
    $server = [string]$ServerInfo.server_name
    $data = Get-HAReplicationData -SqlConnection $SqlConnection -Result $r -Thresholds $Thresholds
    $nd = @($data.Distributors).Count
    $np = @($data.Databases | Where-Object { (Test-HATrue $_.is_published) -or (Test-HATrue $_.is_merge_published) }).Count
    $ns = @($data.Subscriptions).Count
    $leftover = @($data.Databases | Where-Object { [string]$_.log_reuse_wait_desc -eq 'REPLICATION' }).Count
    if ($nd + $np + $ns + $leftover -eq 0) {
        $r.Summary = 'No replication found on this server (not a publisher, distributor or subscriber).'
        Add-HACollectErrorIssues -Result $r -Server $server
        return $r
    }
    $r.Configured = $true
    $parts = @()
    if ($nd) { $r.Roles.Add('Repl Distributor'); $parts += "distributor ($(($data.Distributors | ForEach-Object { $_.Name }) -join ', '))" }
    if ($np) { $r.Roles.Add("Repl Publisher ($np db)"); $parts += "publisher of $np database(s)" }
    if ($ns) { $r.Roles.Add("Repl Subscriber ($ns sub)"); $parts += "subscriber ($ns subscription(s))" }
    $r.Summary = if ($parts.Count) { 'This server is ' + ($parts -join ', ') + '.' } else { 'Replication leftovers detected.' }
    foreach ($i in (Get-HAReplicationIssues -Data $data -Server $server -Thresholds $Thresholds -AgentStatus ([string]$ServerInfo.agent_status))) { $r.Issues.Add($i) }
    Add-HACollectErrorIssues -Result $r -Server $server
    $r.Tables = Get-HAReplicationTables -Data $data -Server $server -Thresholds $Thresholds
    $r
}
'@
#endregion

New-Module -Name SqlHAMonitorEngine -ScriptBlock ([scriptblock]::Create($script:HAEngineCode)) | Import-Module -Force -DisableNameChecking

# What each background runspace runs: load the engine once per runspace, then check one server
$script:HAWorker = @'
param($EngineCode, $Connection, $Features, $Thresholds)
if (-not (Get-Command Invoke-HAServerCheck -ErrorAction SilentlyContinue)) {
    New-Module -Name SqlHAMonitorEngine -ScriptBlock ([scriptblock]::Create($EngineCode)) | Import-Module -DisableNameChecking
}
Invoke-HAServerCheck -Connection $Connection -Features $Features -Thresholds $Thresholds
'@

#region ---------------- state ----------------
$script:FeatureKeys = switch ($Feature) { 'AG' { @('AG') } 'LogShipping' { @('LS') } 'Replication' { @('REPL') } default { @('AG', 'LS', 'REPL') } }
$script:FeatureNames = @{ AG = 'Availability Groups'; LS = 'Log Shipping'; REPL = 'Replication'; ALL = 'Overview' }
$script:Thresholds = Import-HAThresholds -Path $ConfigPath
$script:Connections = ([System.Collections.Generic.List[object]]::new())   # ConnectionInfo objects
$script:Results = @{}                                                         # key = typed server (upper) -> result
$script:Pending = ([System.Collections.Generic.List[object]]::new())
$script:ServerFilter = $null
$script:ShowInfo = $true
$script:Pages = @{}
$script:RefreshQueued = $false
$script:StoreDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'SqlHAMonitor'
$script:StoreFile = Join-Path $script:StoreDir 'servers.json'

$script:Colors = @{
    Critical = [System.Drawing.Color]::FromArgb(255, 214, 214)
    Warning  = [System.Drawing.Color]::FromArgb(255, 238, 196)
    Info     = [System.Drawing.Color]::FromArgb(222, 235, 255)
    OK       = [System.Drawing.Color]::FromArgb(218, 242, 220)
    Running  = [System.Drawing.Color]::FromArgb(240, 240, 240)
}
$script:TextColors = @{
    Critical = [System.Drawing.Color]::FromArgb(176, 0, 0)
    Warning  = [System.Drawing.Color]::FromArgb(150, 90, 0)
    Info     = [System.Drawing.Color]::FromArgb(0, 70, 160)
    OK       = [System.Drawing.Color]::FromArgb(0, 110, 40)
}
#endregion

#region ---------------- background runspace pool ----------------
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
$script:Pool.Open()
#endregion

#region ---------------- helpers ----------------
function Get-HAKey { param([string]$Name) $Name.Trim().ToUpperInvariant() }

function Save-HAServerList {
    try {
        if (-not (Test-Path $script:StoreDir)) { [void](New-Item -ItemType Directory -Path $script:StoreDir) }
        $list = @($script:Connections | ForEach-Object { [pscustomobject]@{ Server = $_.Server; AuthMode = $_.AuthMode; UserName = $_.UserName; Encrypt = $_.Encrypt; TrustServerCertificate = $_.TrustServerCertificate } })
        ConvertTo-Json -InputObject $list -Depth 3 | Set-Content -Path $script:StoreFile -Encoding UTF8
    } catch { }
}

function ConvertTo-HADataTable {
    param([object[]]$Rows)
    $dt = New-Object System.Data.DataTable
    $cols = ([System.Collections.Generic.List[string]]::new())
    foreach ($r in $Rows) { foreach ($p in $r.PSObject.Properties) { if (-not $cols.Contains($p.Name)) { $cols.Add($p.Name) } } }
    foreach ($c in $cols) {
        $sample = $null
        foreach ($r in $Rows) { $pp = $r.PSObject.Properties[$c]; if ($pp -and $null -ne $pp.Value) { $sample = $pp.Value; break } }
        $type = [string]
        if ($sample -is [datetime]) { $type = [datetime] }
        elseif ($sample -is [int] -or $sample -is [long] -or $sample -is [double] -or $sample -is [decimal] -or $sample -is [int16] -or $sample -is [byte] -or $sample -is [single]) { $type = [double] }
        [void]$dt.Columns.Add($c, $type)
    }
    foreach ($r in $Rows) {
        $dr = $dt.NewRow()
        foreach ($c in $cols) {
            $pp = $r.PSObject.Properties[$c]
            $v = $null; if ($pp) { $v = $pp.Value }
            if ($null -eq $v) { $dr[$c] = [System.DBNull]::Value; continue }
            try { $dr[$c] = $v } catch { try { $dr[$c] = [string]$v } catch { $dr[$c] = [System.DBNull]::Value } }
        }
        $dt.Rows.Add($dr)
    }
    , $dt
}

function Set-HAGridColors {
    param($Grid)
    if (-not $Grid.Columns.Contains('Health')) { return }
    foreach ($row in $Grid.Rows) {
        $h = [string]$row.Cells['Health'].Value
        if ($script:Colors.ContainsKey($h)) { $row.DefaultCellStyle.BackColor = $script:Colors[$h] }
    }
}

function New-HAGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.AutoSizeColumnsMode = 'DisplayedCells'
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = 'None'
    $g.ClipboardCopyMode = 'EnableAlwaysIncludeHeaderText'
    $g.Add_DataBindingComplete({ param($s, $e) Set-HAGridColors $s })
    $g
}

function Add-RtbText {
    param($Rtb, [string]$Text, [switch]$Bold, [switch]$Mono, [System.Drawing.Color]$Color = [System.Drawing.Color]::Black, [float]$Size = 9.5)
    $Rtb.SelectionStart = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $family = if ($Mono) { 'Consolas' } else { 'Segoe UI' }
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $Rtb.SelectionFont = New-Object System.Drawing.Font($family, $Size, $style)
    $Rtb.SelectionColor = $Color
    $Rtb.AppendText($Text)
}

function Get-HAConnectionFor {
    param([string]$Name)
    $k = Get-HAKey $Name
    foreach ($c in $script:Connections) {
        if ((Get-HAKey $c.Server) -eq $k) { return $c }
        $r = $script:Results[(Get-HAKey $c.Server)]
        if ($r -and $r.ServerName -and (Get-HAKey $r.ServerName) -eq $k) { return $c }
    }
    $null
}
#endregion

#region ---------------- connection dialog ----------------
function Show-HAConnectDialog {
    param([string]$ServerName = '', [string]$AuthMode = 'Windows', [string]$UserName = '', [string]$Reason = '')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Connect to SQL Server (read-only monitoring)'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.ClientSize = New-Object System.Drawing.Size(430, 300)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $y = 12
    if ($Reason) {
        $lr = New-Object System.Windows.Forms.Label; $lr.Text = $Reason; $lr.Location = New-Object System.Drawing.Point(12, $y); $lr.Size = New-Object System.Drawing.Size(405, 34); $lr.ForeColor = [System.Drawing.Color]::DimGray
        $f.Controls.Add($lr); $y += 38
    }
    $mk = {
        param($text, $yy)
        $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Location = New-Object System.Drawing.Point(12, ($yy + 3)); $l.Size = New-Object System.Drawing.Size(110, 20); $f.Controls.Add($l)
    }
    & $mk 'Server\Instance:' $y
    $tbS = New-Object System.Windows.Forms.TextBox; $tbS.Location = New-Object System.Drawing.Point(125, $y); $tbS.Width = 290; $tbS.Text = $ServerName; $f.Controls.Add($tbS); $y += 32
    & $mk 'Authentication:' $y
    $cbA = New-Object System.Windows.Forms.ComboBox; $cbA.DropDownStyle = 'DropDownList'; $cbA.Location = New-Object System.Drawing.Point(125, $y); $cbA.Width = 290
    [void]$cbA.Items.AddRange(@('Windows Authentication', 'SQL Server Authentication')); $f.Controls.Add($cbA); $y += 32
    & $mk 'Login:' $y
    $tbU = New-Object System.Windows.Forms.TextBox; $tbU.Location = New-Object System.Drawing.Point(125, $y); $tbU.Width = 290; $tbU.Text = $UserName; $f.Controls.Add($tbU); $y += 32
    & $mk 'Password:' $y
    $tbP = New-Object System.Windows.Forms.TextBox; $tbP.Location = New-Object System.Drawing.Point(125, $y); $tbP.Width = 290; $tbP.UseSystemPasswordChar = $true; $f.Controls.Add($tbP); $y += 34
    $chE = New-Object System.Windows.Forms.CheckBox; $chE.Text = 'Encrypt connection'; $chE.Location = New-Object System.Drawing.Point(125, $y); $chE.AutoSize = $true; $f.Controls.Add($chE); $y += 24
    $chT = New-Object System.Windows.Forms.CheckBox; $chT.Text = 'Trust server certificate'; $chT.Checked = $true; $chT.Location = New-Object System.Drawing.Point(125, $y); $chT.AutoSize = $true; $f.Controls.Add($chT); $y += 34

    $toggle = { $sql = ($cbA.SelectedIndex -eq 1); $tbU.Enabled = $sql; $tbP.Enabled = $sql }
    $cbA.Add_SelectedIndexChanged($toggle)
    $cbA.SelectedIndex = $(if ($AuthMode -eq 'Sql') { 1 } else { 0 }); & $toggle

    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Connect'; $ok.Location = New-Object System.Drawing.Point(254, $y); $ok.Width = 78; $ok.DialogResult = 'OK'
    $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancel'; $ca.Location = New-Object System.Drawing.Point(338, $y); $ca.Width = 78; $ca.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($ok, $ca)); $f.AcceptButton = $ok; $f.CancelButton = $ca
    $f.ClientSize = New-Object System.Drawing.Size(430, ($y + 40))
    if ($ServerName) { $f.Add_Shown({ if ($tbU.Enabled -and -not $tbU.Text) { $tbU.Focus() } elseif ($tbP.Enabled) { $tbP.Focus() } }) }

    while ($true) {
        if ($f.ShowDialog($script:Form) -ne 'OK') { $f.Dispose(); return $null }
        try {
            if (-not $tbS.Text.Trim()) { throw 'Please enter a server name.' }
            $mode = if ($cbA.SelectedIndex -eq 1) { 'Sql' } else { 'Windows' }
            $pw = $null
            if ($mode -eq 'Sql') { $pw = New-Object System.Security.SecureString; foreach ($ch in $tbP.Text.ToCharArray()) { $pw.AppendChar($ch) }; $tbP.Text = '' }
            $ci = New-HAConnectionInfo -Server $tbS.Text.Trim() -AuthMode $mode -UserName $tbU.Text.Trim() -Password $pw -Encrypt $chE.Checked -TrustServerCertificate $chT.Checked
            $f.Dispose()
            return $ci
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($f, $_.Exception.Message, 'Connect', 'OK', 'Warning')
        }
    }
}
#endregion

#region ---------------- main form ----------------
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = "SQL Server HA Monitor - $(if ($Feature -eq 'All') { 'AG / Log Shipping / Replication' } else { $script:FeatureNames[$script:FeatureKeys[0]] }) (read-only)"
$script:Form.Size = New-Object System.Drawing.Size(1400, 880)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:Form.AutoScaleMode = 'Dpi'

# toolbar
$tool = New-Object System.Windows.Forms.ToolStrip
$tool.GripStyle = 'Hidden'; $tool.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
$btnAdd = New-Object System.Windows.Forms.ToolStripButton; $btnAdd.Text = '+ Add server'
$btnRemove = New-Object System.Windows.Forms.ToolStripButton; $btnRemove.Text = 'Remove server'
$lblAuto = New-Object System.Windows.Forms.ToolStripLabel; $lblAuto.Text = '   Auto refresh:'
$cbRefresh = New-Object System.Windows.Forms.ToolStripComboBox; $cbRefresh.DropDownStyle = 'DropDownList'; $cbRefresh.Width = 110
[void]$cbRefresh.Items.AddRange(@('Off', 'Every 10 sec', 'Every 30 sec', 'Every 1 min', 'Every 5 min'))
$refreshMap = @(0, 10, 30, 60, 300)
$btnRefresh = New-Object System.Windows.Forms.ToolStripButton; $btnRefresh.Text = 'Refresh now'
$chkInfo = New-Object System.Windows.Forms.ToolStripButton; $chkInfo.Text = 'Show info messages'; $chkInfo.CheckOnClick = $true; $chkInfo.Checked = $true
$btnCfg = New-Object System.Windows.Forms.ToolStripButton; $btnCfg.Text = 'Reload thresholds'
$btnCfg.ToolTipText = "Re-read $ConfigPath"
$lblRO = New-Object System.Windows.Forms.ToolStripLabel; $lblRO.Alignment = 'Right'; $lblRO.Text = 'READ-ONLY: suggested queries are never executed by this tool'; $lblRO.ForeColor = [System.Drawing.Color]::DimGray
[void]$tool.Items.AddRange(@($btnAdd, $btnRemove, (New-Object System.Windows.Forms.ToolStripSeparator), $lblAuto, $cbRefresh, $btnRefresh, (New-Object System.Windows.Forms.ToolStripSeparator), $chkInfo, $btnCfg, $lblRO))

# status bar
$status = New-Object System.Windows.Forms.StatusStrip
$stMain = New-Object System.Windows.Forms.ToolStripStatusLabel; $stMain.Spring = $true; $stMain.TextAlign = 'MiddleLeft'; $stMain.Text = 'Add a server to start.'
$stLast = New-Object System.Windows.Forms.ToolStripStatusLabel; $stLast.Text = ''
[void]$status.Items.AddRange(@($stMain, $stLast))

# left: servers
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.FixedPanel = 'Panel1'
$lvServers = New-Object System.Windows.Forms.ListView
$lvServers.Dock = 'Fill'; $lvServers.View = 'Details'; $lvServers.FullRowSelect = $true; $lvServers.HideSelection = $false; $lvServers.MultiSelect = $false
[void]$lvServers.Columns.Add('Server', 130); [void]$lvServers.Columns.Add('Status', 70); [void]$lvServers.Columns.Add('Roles', 260)
$lblServers = New-Object System.Windows.Forms.Label; $lblServers.Text = '  Monitored servers (click to filter)'; $lblServers.Dock = 'Top'; $lblServers.Height = 24; $lblServers.TextAlign = 'MiddleLeft'
$lblServers.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$split.Panel1.Controls.Add($lvServers); $split.Panel1.Controls.Add($lblServers)

# right: tabs
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$split.Panel2.Controls.Add($tabs)

function Initialize-HASplit {
    <# Sets the splitter position once the control has a real size (setting it earlier throws in WinForms). #>
    param($Split, [double]$Ratio)
    $Split.Tag = $Ratio
    $Split.Add_SizeChanged({
            param($s, $e)
            if ($s.Tag -isnot [double]) { return }
            $len = if ($s.Orientation -eq 'Horizontal') { $s.Height } else { $s.Width }
            if ($len -lt 150) { return }
            try { $s.SplitterDistance = [int]($len * [double]$s.Tag); $s.Tag = 'set' } catch { }
        })
}

function New-HAFeaturePage {
    param([string]$Key)
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $script:FeatureNames[$Key]
    $page.Padding = New-Object System.Windows.Forms.Padding(4)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Dock = 'Top'; $summary.Height = 46; $summary.Padding = New-Object System.Windows.Forms.Padding(4)
    $summary.Text = 'Waiting for first refresh...'

    $vsplit = New-Object System.Windows.Forms.SplitContainer
    $vsplit.Dock = 'Fill'; $vsplit.Orientation = 'Horizontal'
    Initialize-HASplit -Split $vsplit -Ratio 0.42

    $dataTabs = New-Object System.Windows.Forms.TabControl; $dataTabs.Dock = 'Fill'
    $vsplit.Panel1.Controls.Add($dataTabs)

    $hsplit = New-Object System.Windows.Forms.SplitContainer
    $hsplit.Dock = 'Fill'
    Initialize-HASplit -Split $hsplit -Ratio 0.45
    $vsplit.Panel2.Controls.Add($hsplit)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
    [void]$lv.Columns.Add('Severity', 70); [void]$lv.Columns.Add('Server', 110); [void]$lv.Columns.Add('Issue', 420)
    $lblIssues = New-Object System.Windows.Forms.Label; $lblIssues.Text = '  Findings (select one for explanation and steps)'; $lblIssues.Dock = 'Top'; $lblIssues.Height = 22; $lblIssues.TextAlign = 'MiddleLeft'
    $lblIssues.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $hsplit.Panel1.Controls.Add($lv); $hsplit.Panel1.Controls.Add($lblIssues)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock = 'Fill'; $rtb.ReadOnly = $true; $rtb.BackColor = [System.Drawing.Color]::White; $rtb.DetectUrls = $true; $rtb.BorderStyle = 'None'
    $rtb.Add_LinkClicked({ param($s, $e) try { Start-Process $e.LinkText } catch { } })
    $btnBar = New-Object System.Windows.Forms.FlowLayoutPanel; $btnBar.Dock = 'Top'; $btnBar.Height = 34; $btnBar.Padding = New-Object System.Windows.Forms.Padding(2)
    $bConnect = New-Object System.Windows.Forms.Button; $bConnect.AutoSize = $true; $bConnect.Visible = $false
    $bConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 102, 204); $bConnect.ForeColor = [System.Drawing.Color]::White; $bConnect.FlatStyle = 'Flat'
    $bCopyQ = New-Object System.Windows.Forms.Button; $bCopyQ.Text = 'Copy queries'; $bCopyQ.AutoSize = $true; $bCopyQ.Enabled = $false
    $bCopyI = New-Object System.Windows.Forms.Button; $bCopyI.Text = 'Copy full write-up'; $bCopyI.AutoSize = $true; $bCopyI.Enabled = $false
    $btnBar.Controls.AddRange(@($bConnect, $bCopyQ, $bCopyI))
    $hsplit.Panel2.Controls.Add($rtb); $hsplit.Panel2.Controls.Add($btnBar)

    $page.Controls.Add($vsplit); $page.Controls.Add($summary)

    $ctx = @{ Key = $Key; Page = $page; Summary = $summary; DataTabs = $dataTabs; Grids = @{}; Issues = $lv; Details = $rtb; Connect = $bConnect; CopyQ = $bCopyQ; CopyI = $bCopyI; Selected = $null; VSplit = $vsplit }

    $lv.Tag = $ctx
    $lv.Add_SelectedIndexChanged({
            param($s, $e)
            $c = $s.Tag
            if ($s.SelectedItems.Count -eq 0) { return }
            $c.Selected = $s.SelectedItems[0].Tag
            Show-HAIssueDetails -Ctx $c
        })
    $bConnect.Tag = $ctx
    $bConnect.Add_Click({ param($s, $e) $c = $s.Tag; if ($c.Selected -and $c.Selected.ConnectTo) { Connect-HAFromIssue -Issue $c.Selected } })
    $bCopyQ.Tag = $ctx
    $bCopyQ.Add_Click({
            param($s, $e)
            $c = $s.Tag; if (-not $c.Selected) { return }
            $txt = (@($c.Selected.Queries) | ForEach-Object { "-- $($_.Title)  [$(if ($_.Kind -eq 'Fix') { 'FIX - review before running' } else { 'VERIFY - read-only' })]  Run on: $($_.RunOn)`r`n$($_.Sql)`r`n" }) -join "`r`n"
            if ($txt) { [System.Windows.Forms.Clipboard]::SetText($txt); $stMain.Text = 'Queries copied to clipboard.' }
        })
    $bCopyI.Tag = $ctx
    $bCopyI.Add_Click({ param($s, $e) $c = $s.Tag; if ($c.Selected) { [System.Windows.Forms.Clipboard]::SetText((ConvertTo-HAIssueText -Issue $c.Selected)); $stMain.Text = 'Write-up copied to clipboard.' } })
    $ctx
}

$script:Pages['ALL'] = New-HAFeaturePage -Key 'ALL'
[void]$tabs.TabPages.Add($script:Pages['ALL'].Page)
foreach ($k in $script:FeatureKeys) { $script:Pages[$k] = New-HAFeaturePage -Key $k; [void]$tabs.TabPages.Add($script:Pages[$k].Page) }
if ($script:FeatureKeys.Count -eq 1) { $tabs.SelectedIndex = 1 }

$script:Form.Controls.Add($split)
$script:Form.Controls.Add($tool)
$script:Form.Controls.Add($status)
#endregion

#region ---------------- rendering ----------------
function Show-HAIssueDetails {
    param($Ctx)
    $i = $Ctx.Selected
    $rtb = $Ctx.Details
    $rtb.Clear()
    if (-not $i) { $Ctx.Connect.Visible = $false; $Ctx.CopyQ.Enabled = $false; $Ctx.CopyI.Enabled = $false; return }
    $sevColor = $script:TextColors[$i.Severity]; if (-not $sevColor) { $sevColor = [System.Drawing.Color]::Black }
    Add-RtbText $rtb "$($i.Severity.ToUpper())  " -Bold -Color $sevColor -Size 10
    Add-RtbText $rtb "$($i.Title)`r`n" -Bold -Size 10.5
    Add-RtbText $rtb "Server: $($i.Server)    Area: $($script:FeatureNames[$i.Feature])$(if ($i.Object) { "    Object: $($i.Object)" })`r`n`r`n" -Color ([System.Drawing.Color]::DimGray) -Size 8.5
    if ($i.Explanation) { Add-RtbText $rtb "What is going on`r`n" -Bold; Add-RtbText $rtb "$($i.Explanation)`r`n`r`n" }
    if ($i.Impact) { Add-RtbText $rtb "Why it matters`r`n" -Bold; Add-RtbText $rtb "$($i.Impact)`r`n`r`n" }
    if ($i.ConnectTo) {
        $known = Get-HAConnectionFor $i.ConnectTo
        Add-RtbText $rtb "Where to look next`r`n" -Bold
        Add-RtbText $rtb "$($i.ConnectTo) - $($i.ConnectReason)$(if ($known) { ' (already monitored - select it on the left)' })`r`n`r`n" -Color $script:TextColors['Info']
    }
    if (@($i.Steps).Count) {
        Add-RtbText $rtb "Steps to troubleshoot / resolve`r`n" -Bold
        $n = 1; foreach ($s in $i.Steps) { Add-RtbText $rtb "  $n. $s`r`n"; $n++ }
        Add-RtbText $rtb "`r`n"
    }
    if (@($i.Queries).Count) {
        Add-RtbText $rtb "Suggested queries (NOT executed - copy and review before running)`r`n" -Bold
        foreach ($q in $i.Queries) {
            $isFix = ($q.Kind -eq 'Fix')
            Add-RtbText $rtb "  $(if ($isFix) { '[FIX - changes something, review first]' } else { '[VERIFY - read-only]' }) " -Bold -Color $(if ($isFix) { $script:TextColors['Critical'] } else { $script:TextColors['OK'] }) -Size 8.5
            Add-RtbText $rtb "$($q.Title)   -   run on: $($q.RunOn)`r`n" -Size 8.5
            Add-RtbText $rtb "$($q.Sql)`r`n`r`n" -Mono -Color ([System.Drawing.Color]::FromArgb(30, 30, 110)) -Size 9
        }
    }
    if (@($i.Links).Count) {
        Add-RtbText $rtb "Further reading`r`n" -Bold
        foreach ($l in $i.Links) { Add-RtbText $rtb "  $($l.Title)`r`n  $($l.Url)`r`n" }
    }
    $rtb.SelectionStart = 0; $rtb.ScrollToCaret()

    $Ctx.CopyQ.Enabled = (@($i.Queries).Count -gt 0)
    $Ctx.CopyI.Enabled = $true
    if ($i.ConnectTo) {
        $known = Get-HAConnectionFor $i.ConnectTo
        $Ctx.Connect.Text = $(if ($known) { "Show $($i.ConnectTo)" } else { "Connect to $($i.ConnectTo)" })
        $Ctx.Connect.Visible = $true
    } else { $Ctx.Connect.Visible = $false }
}

function Get-HAVisibleResults {
    $out = @()
    foreach ($c in $script:Connections) {
        $k = Get-HAKey $c.Server
        if ($script:ServerFilter -and $k -ne $script:ServerFilter) { continue }
        if ($script:Results.ContainsKey($k)) { $out += $script:Results[$k] }
    }
    $out
}

function Update-HAServerList {
    $selKey = $script:ServerFilter
    $lvServers.BeginUpdate()
    $lvServers.Items.Clear()
    $all = New-Object System.Windows.Forms.ListViewItem('(All servers)')
    [void]$all.SubItems.Add(''); [void]$all.SubItems.Add("$($script:Connections.Count) server(s)")
    $all.Tag = $null
    [void]$lvServers.Items.Add($all)
    foreach ($c in $script:Connections) {
        $k = Get-HAKey $c.Server
        $r = $script:Results[$k]
        $running = @($script:Pending | Where-Object { $_.Key -eq $k }).Count -gt 0
        $st = if ($r) { $r.Status } elseif ($running) { 'Checking' } else { '' }
        $name = $c.Server
        if ($r -and $r.ServerName -and (Get-HAKey $r.ServerName) -ne $k) { $name = "$($c.Server) ($($r.ServerName))" }
        $it = New-Object System.Windows.Forms.ListViewItem($name)
        [void]$it.SubItems.Add($(if ($r -and -not $r.Connected) { 'NO CONN' } else { $st }))
        [void]$it.SubItems.Add($(if ($r) { ($r.Roles -join ', ') } else { '' }))
        $it.Tag = $k
        if ($r -and $script:Colors.ContainsKey($r.Status)) { $it.BackColor = $script:Colors[$r.Status] }
        [void]$lvServers.Items.Add($it)
        if ($selKey -and $selKey -eq $k) { $it.Selected = $true }
    }
    if (-not $selKey) { $all.Selected = $true }
    $lvServers.EndUpdate()
}

function Update-HAGrids {
    param($Ctx, [System.Collections.Specialized.OrderedDictionary]$Tables)
    foreach ($name in $Tables.Keys) {
        if (-not $Ctx.Grids.ContainsKey($name)) {
            $tp = New-Object System.Windows.Forms.TabPage; $tp.Text = $name
            $g = New-HAGrid; $tp.Controls.Add($g)
            [void]$Ctx.DataTabs.TabPages.Add($tp)
            $Ctx.Grids[$name] = @{ Grid = $g; Page = $tp }
        }
        $entry = $Ctx.Grids[$name]
        $rows = @($Tables[$name])
        $entry.Page.Text = "$name ($($rows.Count))"
        $g = $entry.Grid
        $first = -1; try { $first = $g.FirstDisplayedScrollingRowIndex } catch { }
        $sortCol = $null; $sortDir = $null
        if ($g.SortedColumn) { $sortCol = $g.SortedColumn.Name; $sortDir = $g.SortOrder }
        $g.DataSource = $null
        if ($rows.Count -gt 0) {
            $g.DataSource = (ConvertTo-HADataTable -Rows $rows)
            if ($sortCol -and $g.Columns.Contains($sortCol)) {
                $dir = if ($sortDir -eq 'Descending') { [System.ComponentModel.ListSortDirection]::Descending } else { [System.ComponentModel.ListSortDirection]::Ascending }
                $g.Sort($g.Columns[$sortCol], $dir)
            }
            if ($first -ge 0 -and $first -lt $g.RowCount) { try { $g.FirstDisplayedScrollingRowIndex = $first } catch { } }
        }
    }
}

function Update-HAIssueList {
    param($Ctx, [object[]]$Issues)
    $lv = $Ctx.Issues
    $selKey = $null
    if ($Ctx.Selected) { $selKey = "$($Ctx.Selected.Server)|$($Ctx.Selected.Feature)|$($Ctx.Selected.Title)" }
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $sorted = @($Issues | Where-Object { $script:ShowInfo -or $_.Severity -ne 'Info' } |
            Sort-Object @{ Expression = { Get-HASeverityRank $_.Severity }; Descending = $true }, Server, Title)
    $reselected = $null
    foreach ($i in $sorted) {
        $it = New-Object System.Windows.Forms.ListViewItem($i.Severity)
        [void]$it.SubItems.Add([string]$i.Server)
        [void]$it.SubItems.Add($(if ($Ctx.Key -eq 'ALL') { "[$($i.Feature)] $($i.Title)" } else { $i.Title }))
        $it.Tag = $i
        if ($script:Colors.ContainsKey($i.Severity)) { $it.BackColor = $script:Colors[$i.Severity] }
        [void]$lv.Items.Add($it)
        if ($selKey -and "$($i.Server)|$($i.Feature)|$($i.Title)" -eq $selKey) { $reselected = $it }
    }
    if ($sorted.Count -eq 0) {
        $it = New-Object System.Windows.Forms.ListViewItem('OK')
        [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('No problems found.'); $it.BackColor = $script:Colors['OK']
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    if ($reselected) { $reselected.Selected = $true; $Ctx.Selected = $reselected.Tag; Show-HAIssueDetails -Ctx $Ctx }
    else { $Ctx.Selected = $null; Show-HAIssueDetails -Ctx $Ctx }
}

function Update-HAView {
    $results = @(Get-HAVisibleResults)
    $crit = 0; $warn = 0

    # ---- feature pages ----
    foreach ($k in $script:FeatureKeys) {
        $ctx = $script:Pages[$k]
        $issues = @(); $summaries = @()
        $merged = [ordered]@{}
        foreach ($r in $results) {
            if (-not $r.Features.Contains($k)) { continue }
            $fr = $r.Features[$k]
            $summaries += "$($r.ServerName): $($fr.Summary)"
            foreach ($x in $fr.Issues) { $issues += $x }
            foreach ($tn in $fr.Tables.Keys) {
                if (-not $merged.Contains($tn)) { $merged[$tn] = ([System.Collections.Generic.List[object]]::new()) }
                foreach ($row in @($fr.Tables[$tn])) {
                    $o = [ordered]@{ Server = $r.ServerName }
                    foreach ($p in $row.PSObject.Properties) { $o[$p.Name] = $p.Value }
                    # keep Health first for readability
                    $h = [ordered]@{}; if ($o.Contains('Health')) { $h['Health'] = $o['Health'] }; foreach ($kk in $o.Keys) { if ($kk -ne 'Health') { $h[$kk] = $o[$kk] } }
                    $merged[$tn].Add([pscustomobject]$h)
                }
            }
        }
        $ctx.Summary.Text = $(if ($summaries.Count) { $summaries -join "`r`n" } else { 'No data yet.' })
        $tables = [ordered]@{}; foreach ($tn in $merged.Keys) { $tables[$tn] = $merged[$tn].ToArray() }
        Update-HAGrids -Ctx $ctx -Tables $tables
        Update-HAIssueList -Ctx $ctx -Issues $issues
        $w = Get-HAWorstSeverity $issues
        $ctx.Page.Text = "$($script:FeatureNames[$k])$(switch ($w) { 'Critical' { '  (!!)' } 'Warning' { '  (!)' } default { '' } })"
    }

    # ---- overview ----
    $ov = $script:Pages['ALL']
    $allIssues = @(); $srvRows = @()
    foreach ($r in $results) {
        $allIssues += @($r.Issues | Where-Object { $_.Feature -eq 'SERVER' -or $script:FeatureKeys -contains $_.Feature })
        $row = [ordered]@{
            Health  = $r.Status
            Server  = $r.ServerName
            Connected = $(if ($r.Connected) { 'Yes' } else { 'NO' })
            Version = $(if ($r.Info) { "$($r.Info.product_version) $($r.Info.product_level)" } else { '' })
            Edition = $(if ($r.Info) { $r.Info.edition } else { '' })
            'SQL Agent' = $(if ($r.Info) { $r.Info.agent_status } else { '' })
            Roles   = ($r.Roles -join ', ')
        }
        foreach ($k in $script:FeatureKeys) { $row["$k summary"] = $(if ($r.Features.Contains($k)) { $r.Features[$k].Summary } else { '' }) }
        $row['Check (ms)'] = $r.DurationMs
        $row['Checked At'] = $r.CheckedAt
        $row['Error'] = $r.Error
        $srvRows += [pscustomobject]$row
    }
    foreach ($i in $allIssues) { if ($i.Severity -eq 'Critical') { $crit++ } elseif ($i.Severity -eq 'Warning') { $warn++ } }
    $ov.Summary.Text = "$($results.Count) server(s) shown.   Critical: $crit    Warning: $warn`r`nSelect a finding below for a plain-English explanation, steps and suggested queries."
    $t = [ordered]@{}; $t['Servers'] = $srvRows
    Update-HAGrids -Ctx $ov -Tables $t
    Update-HAIssueList -Ctx $ov -Issues $allIssues

    Update-HAServerList
}
#endregion

#region ---------------- refresh engine ----------------
function Start-HARefresh {
    param([string[]]$OnlyKeys)
    if ($script:Pending.Count -gt 0) { $script:RefreshQueued = $true; return }
    if ($script:Connections.Count -eq 0) { $stMain.Text = 'Add a server to start.'; return }
    $script:RefreshStarted = Get-Date
    foreach ($c in $script:Connections) {
        $k = Get-HAKey $c.Server
        if ($OnlyKeys -and $OnlyKeys -notcontains $k) { continue }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($script:HAWorker).AddParameter('EngineCode', $script:HAEngineCode).AddParameter('Connection', $c).AddParameter('Features', [string[]]$script:FeatureKeys).AddParameter('Thresholds', $script:Thresholds)
        $script:Pending.Add([pscustomobject]@{ Key = $k; PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date })
    }
    $stMain.Text = "Checking $($script:Pending.Count) server(s)..."
    $btnRefresh.Enabled = $false
    Update-HAServerList
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 300
$pollTimer.Add_Tick({
      try {
        if ($script:Pending.Count -eq 0) { return }
        $done = @($script:Pending | Where-Object { $_.Handle.IsCompleted })
        foreach ($p in $done) {
            try {
                $out = $p.PS.EndInvoke($p.Handle)
                $res = $null; foreach ($o in $out) { if ($o -and $o.PSObject.Properties['Features']) { $res = $o } }
                if (-not $res) {
                    $err = ($p.PS.Streams.Error | Select-Object -First 1)
                    throw "No result returned. $err"
                }
                $script:Results[$p.Key] = $res
            } catch {
                $script:Results[$p.Key] = [pscustomobject]@{
                    Server = $p.Key; ServerName = $p.Key; Connected = $false; Info = $null; Error = $_.Exception.Message
                    Features = [ordered]@{}; Roles = @(); Status = 'Critical'; CheckedAt = Get-Date; DurationMs = 0
                    Issues = @(New-HAIssue -Severity Critical -Feature SERVER -Server $p.Key -Title 'Check failed' -Explanation $_.Exception.Message)
                }
            } finally { $p.PS.Dispose(); [void]$script:Pending.Remove($p) }
        }
        if ($script:Pending.Count -eq 0) {
            $btnRefresh.Enabled = $true
            $secs = [math]::Round(((Get-Date) - $script:RefreshStarted).TotalSeconds, 1)
            $stMain.Text = "Refreshed $($script:Connections.Count) server(s) in $secs s."
            try { Update-HAView } catch { $stMain.Text = "Display error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }
            $stLast.Text = "Last refresh: $((Get-Date).ToString('HH:mm:ss'))"
            if ($script:RefreshQueued) { $script:RefreshQueued = $false; Start-HARefresh }
        } else {
            $stMain.Text = "Waiting for $($script:Pending.Count) server(s): $(($script:Pending | ForEach-Object { $_.Key }) -join ', ')"
        }
      } catch {
        # never let a timer error pop up the WinForms crash dialog every 300 ms
        $stMain.Text = "Refresh error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        $btnRefresh.Enabled = $true
      }
    })

$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Add_Tick({ try { Start-HARefresh } catch { $stMain.Text = "Refresh error: $($_.Exception.Message)" } })

function Set-HAAutoRefresh {
    param([int]$Seconds)
    $autoTimer.Stop()
    if ($Seconds -gt 0) { $autoTimer.Interval = $Seconds * 1000; $autoTimer.Start() }
}

function Add-HAServer {
    param($ConnectionInfo, [switch]$NoRefresh)
    $k = Get-HAKey $ConnectionInfo.Server
    $existing = Get-HAConnectionFor $ConnectionInfo.Server
    if ($existing) { $script:ServerFilter = Get-HAKey $existing.Server; Update-HAView; return }
    $script:Connections.Add($ConnectionInfo)
    Save-HAServerList
    Update-HAServerList
    if (-not $NoRefresh) {
        if ($script:Pending.Count -gt 0) { $script:RefreshQueued = $true } else { Start-HARefresh -OnlyKeys @($k) }
    }
}

function Connect-HAFromIssue {
    param($Issue)
    $target = [string]$Issue.ConnectTo
    $known = Get-HAConnectionFor $target
    if ($known) {
        $script:ServerFilter = Get-HAKey $known.Server
        Update-HAView
        $stMain.Text = "Showing $target."
        return
    }
    # inherit auth from the server the issue came from
    $src = Get-HAConnectionFor ([string]$Issue.Server)
    if ($src -and $src.AuthMode -eq 'Windows') {
        $ci = New-HAConnectionInfo -Server $target -AuthMode Windows -Encrypt $src.Encrypt -TrustServerCertificate $src.TrustServerCertificate
    } else {
        $ci = Show-HAConnectDialog -ServerName $target -AuthMode $(if ($src) { $src.AuthMode } else { 'Windows' }) -UserName $(if ($src) { $src.UserName } else { '' }) -Reason "$($Issue.ConnectReason)"
        if (-not $ci) { return }
    }
    Add-HAServer -ConnectionInfo $ci
    $stMain.Text = "Added $target - checking..."
}
#endregion

#region ---------------- events ----------------
$btnAdd.Add_Click({ $ci = Show-HAConnectDialog; if ($ci) { Add-HAServer -ConnectionInfo $ci } })
$btnRemove.Add_Click({
        if (-not $script:ServerFilter) { [void][System.Windows.Forms.MessageBox]::Show($script:Form, 'Select a server on the left first.', 'Remove server'); return }
        $c = @($script:Connections | Where-Object { (Get-HAKey $_.Server) -eq $script:ServerFilter }) | Select-Object -First 1
        if ($c) { [void]$script:Connections.Remove($c); $script:Results.Remove($script:ServerFilter); $script:ServerFilter = $null; Save-HAServerList; Update-HAView }
    })
$btnRefresh.Add_Click({ Start-HARefresh })
$cbRefresh.Add_SelectedIndexChanged({ Set-HAAutoRefresh -Seconds $refreshMap[$cbRefresh.SelectedIndex]; if ($refreshMap[$cbRefresh.SelectedIndex] -gt 0) { $stMain.Text = "Auto refresh: $($cbRefresh.SelectedItem)" } })
$chkInfo.Add_CheckedChanged({ $script:ShowInfo = $chkInfo.Checked; Update-HAView })
$btnCfg.Add_Click({ $script:Thresholds = Import-HAThresholds -Path $ConfigPath; $stMain.Text = "Thresholds reloaded from $ConfigPath"; Start-HARefresh })
$lvServers.Add_SelectedIndexChanged({
        if ($lvServers.SelectedItems.Count -eq 0) { return }
        $new = $lvServers.SelectedItems[0].Tag
        if ($new -ne $script:ServerFilter) { $script:ServerFilter = $new; Update-HAView }
    })
$script:Form.Add_FormClosing({
        try { $autoTimer.Stop(); $pollTimer.Stop() } catch { }
        foreach ($p in $script:Pending.ToArray()) { try { $p.PS.Stop(); $p.PS.Dispose() } catch { } }
        try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
    })
$script:Form.Add_Shown({
        # initial servers: -Server parameter, otherwise the saved list
        if ($Server.Count) {
            foreach ($s in ($Server -split ',')) { if ($s.Trim()) { $script:Connections.Add((New-HAConnectionInfo -Server $s.Trim())) } }
            Save-HAServerList
        } elseif (Test-Path $script:StoreFile) {
            try {
                foreach ($s in @(Get-Content $script:StoreFile -Raw | ConvertFrom-Json)) {
                    if ($s.AuthMode -eq 'Sql') {
                        $ci = Show-HAConnectDialog -ServerName $s.Server -AuthMode Sql -UserName $s.UserName -Reason 'Saved server uses SQL authentication - enter the password (passwords are never saved).'
                        if ($ci) { $script:Connections.Add($ci) }
                    } else {
                        $script:Connections.Add((New-HAConnectionInfo -Server $s.Server -AuthMode Windows -Encrypt ([bool]$s.Encrypt) -TrustServerCertificate ([bool]$s.TrustServerCertificate)))
                    }
                }
            } catch { $stMain.Text = "Could not load saved servers: $($_.Exception.Message)" }
        }
        try { $split.SplitterDistance = 330 } catch { }
        $cbRefresh.SelectedIndex = [array]::IndexOf($refreshMap, $RefreshSeconds)
        $pollTimer.Start()
        Update-HAView
        if ($script:Connections.Count) { Start-HARefresh } else { $ci = Show-HAConnectDialog; if ($ci) { Add-HAServer -ConnectionInfo $ci } }
    })
#endregion

[void]$script:Form.ShowDialog()
$script:Form.Dispose()
