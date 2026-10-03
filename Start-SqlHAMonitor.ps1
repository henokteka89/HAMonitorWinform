#Requires -Version 5.1
<#
.SYNOPSIS
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
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'AG', 'LogShipping', 'Replication')][string]$Feature = 'All',
    [string[]]$Server = @(),
    [ValidateSet(0, 10, 30, 60, 300)][int]$RefreshSeconds = 30,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

# ---------- WinForms needs an STA thread ----------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
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

$modDir = Join-Path $PSScriptRoot 'Modules'
$modPaths = @('SqlHAMonitor.Core.psm1', 'SqlHAMonitor.AG.psm1', 'SqlHAMonitor.LogShipping.psm1', 'SqlHAMonitor.Replication.psm1') | ForEach-Object { Join-Path $modDir $_ }
Import-Module $modPaths -Force -DisableNameChecking

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
$iss.ImportPSModule([string[]]$modPaths)
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
        [void]$ps.AddCommand('Invoke-HAServerCheck').AddParameter('Connection', $c).AddParameter('Features', [string[]]$script:FeatureKeys).AddParameter('Thresholds', $script:Thresholds)
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
