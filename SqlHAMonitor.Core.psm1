#Requires -Version 5.1
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

Set-StrictMode -Version 2.0

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

Export-ModuleMember -Function * -Variable HALinks
