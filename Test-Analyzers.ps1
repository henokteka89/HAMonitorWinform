<#
    Offline tests for the analysis rules (no SQL Server needed).
    Feeds realistic fake DMV/msdb/distribution rows into each analyzer and checks the issues produced.
    Run:  powershell -File .\Tests\Test-Analyzers.ps1      (exit code 1 on failure)
#>
param([switch]$ShowIssues)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot
Import-Module "$root/Modules/SqlHAMonitor.Core.psm1", "$root/Modules/SqlHAMonitor.AG.psm1", "$root/Modules/SqlHAMonitor.LogShipping.psm1", "$root/Modules/SqlHAMonitor.Replication.psm1" -Force

$script:fail = 0; $script:pass = 0
function Assert([bool]$cond, [string]$msg) { if ($cond) { $script:pass++; Write-Host "  PASS  $msg" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL  $msg" -ForegroundColor Red } }
function Row([string[]]$cols, [hashtable]$v) { $h = [ordered]@{}; foreach ($c in $cols) { $h[$c] = $null }; foreach ($k in $v.Keys) { $h[$k] = $v[$k] }; [pscustomobject]$h }
function Find($issues, [string]$sev, [string]$like) { , @($issues | Where-Object { $_.Severity -eq $sev -and $_.Title -like $like }) }
function Show($issues) { if ($ShowIssues) { $issues | ForEach-Object { Write-Host ("    [{0}] {1}{2}" -f $_.Severity, $_.Title, $(if ($_.ConnectTo) { "  -> connect $($_.ConnectTo)" })) -ForegroundColor DarkGray } } }

$T = Get-HADefaultThresholds
$now = Get-Date

# column sets = exactly what the collector queries return
$cG = 'group_id', 'ag_name', 'failure_condition_level', 'health_check_timeout', 'primary_replica', 'primary_recovery_health_desc', 'ag_sync_health'
$cR = 'group_id', 'replica_id', 'replica_server_name', 'endpoint_url', 'availability_mode_desc', 'failover_mode_desc', 'secondary_role_allow_connections_desc', 'session_timeout', 'is_local', 'role_desc', 'operational_state_desc', 'connected_state_desc', 'recovery_health_desc', 'synchronization_health_desc', 'last_connect_error_number', 'last_connect_error_description', 'last_connect_error_timestamp'
$cD = 'group_id', 'replica_id', 'replica_server_name', 'availability_mode_desc', 'failover_mode_desc', 'group_database_id', 'database_name', 'is_failover_ready', 'is_database_joined', 'is_local', 'synchronization_state_desc', 'synchronization_health_desc', 'database_state_desc', 'is_suspended', 'suspend_reason_desc', 'log_send_queue_size', 'log_send_rate', 'redo_queue_size', 'redo_rate', 'last_sent_time', 'last_received_time', 'last_hardened_time', 'last_redone_time', 'last_commit_time'
$cL = 'group_id', 'dns_name', 'port', 'ip_address', 'ip_subnet_mask', 'ip_state'
$cE = 'name', 'state_desc', 'role_desc', 'connection_auth_desc', 'encryption_algorithm_desc', 'port'

Write-Host "`n=== AG: connected to PRIMARY with problems ===" -ForegroundColor Cyan
$g = 'G1'; $r1 = 'R1'; $r2 = 'R2'; $r3 = 'R3'; $dbS = 'DB-S'; $dbH = 'DB-H'
$agData = @{
    Groups    = @(Row $cG @{ group_id = $g; ag_name = 'AG_Sales'; primary_replica = 'SQL01'; ag_sync_health = 'NOT_HEALTHY' })
    Replicas  = @(
        (Row $cR @{ group_id = $g; replica_id = $r1; replica_server_name = 'SQL01'; is_local = $true; role_desc = 'PRIMARY'; operational_state_desc = 'ONLINE'; connected_state_desc = 'CONNECTED'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; synchronization_health_desc = 'HEALTHY' }),
        (Row $cR @{ group_id = $g; replica_id = $r2; replica_server_name = 'SQL02'; is_local = $false; role_desc = 'SECONDARY'; connected_state_desc = 'CONNECTED'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; synchronization_health_desc = 'PARTIALLY_HEALTHY'; endpoint_url = 'TCP://SQL02:5022' }),
        (Row $cR @{ group_id = $g; replica_id = $r3; replica_server_name = 'SQL03'; is_local = $false; role_desc = 'SECONDARY'; connected_state_desc = 'DISCONNECTED'; availability_mode_desc = 'ASYNCHRONOUS_COMMIT'; synchronization_health_desc = 'NOT_HEALTHY'; last_connect_error_number = 10060; last_connect_error_description = 'A connection attempt failed (timeout).'; endpoint_url = 'TCP://SQL03:5022' })
    )
    Databases = @(
        (Row $cD @{ group_id = $g; replica_id = $r1; replica_server_name = 'SQL01'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; group_database_id = $dbS; database_name = 'SalesDB'; is_database_joined = $true; is_failover_ready = $false; is_local = $true; synchronization_state_desc = 'SYNCHRONIZED'; synchronization_health_desc = 'HEALTHY'; database_state_desc = 'ONLINE'; is_suspended = $false; last_commit_time = $now }),
        (Row $cD @{ group_id = $g; replica_id = $r2; replica_server_name = 'SQL02'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; group_database_id = $dbS; database_name = 'SalesDB'; is_database_joined = $true; is_failover_ready = $false; is_local = $false; synchronization_state_desc = 'SYNCHRONIZING'; synchronization_health_desc = 'PARTIALLY_HEALTHY'; is_suspended = $false; log_send_queue_size = 204800; log_send_rate = 1000; redo_queue_size = 1024; redo_rate = 5000; last_commit_time = $now.AddSeconds(-120) }),
        (Row $cD @{ group_id = $g; replica_id = $r3; replica_server_name = 'SQL03'; availability_mode_desc = 'ASYNCHRONOUS_COMMIT'; group_database_id = $dbS; database_name = 'SalesDB'; is_database_joined = $true; is_local = $false; synchronization_state_desc = 'NOT SYNCHRONIZING'; synchronization_health_desc = 'NOT_HEALTHY'; is_suspended = $false; last_commit_time = $now.AddHours(-1) }),
        (Row $cD @{ group_id = $g; replica_id = $r1; replica_server_name = 'SQL01'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; group_database_id = $dbH; database_name = 'HRDB'; is_database_joined = $true; is_local = $true; synchronization_state_desc = 'SYNCHRONIZED'; synchronization_health_desc = 'HEALTHY'; database_state_desc = 'ONLINE'; is_suspended = $false; last_commit_time = $now }),
        (Row $cD @{ group_id = $g; replica_id = $r2; replica_server_name = 'SQL02'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; group_database_id = $dbH; database_name = 'HRDB'; is_database_joined = $false })
    )
    Listeners = @(
        (Row $cL @{ group_id = $g; dns_name = 'AGSalesLsn'; port = 1433; ip_address = '10.0.1.50'; ip_state = 'ONLINE' }),
        (Row $cL @{ group_id = $g; dns_name = 'AGSalesLsn'; port = 1433; ip_address = '10.0.2.50'; ip_state = 'OFFLINE' })   # multi-subnet: normal
    )
    Cluster   = @([pscustomobject]@{ cluster_name = 'CLU1'; quorum_type_desc = 'NODE_AND_FILE_SHARE_MAJORITY'; quorum_state_desc = 'NORMAL_QUORUM' })
    Members   = @([pscustomobject]@{ member_name = 'SQL03'; member_type_desc = 'CLUSTER_NODE'; member_state_desc = 'DOWN'; number_of_quorum_votes = 1 })
    Endpoints = @(Row $cE @{ name = 'Hadr_endpoint'; state_desc = 'STARTED'; port = 5022 })
    RedoBlocking = @()
}
$i = Get-HAAgIssues -Data $agData -Server 'SQL01' -Thresholds $T; Show $i
Assert ((Find $i 'Critical' 'Secondary SQL03 is DISCONNECTED').Count -eq 1) 'Disconnected secondary reported once (root cause)'
Assert ((Find $i 'Critical' 'Secondary SQL03*')[0].ConnectTo -eq 'SQL03') 'Disconnected secondary offers connection to that secondary'
Assert (@($i | Where-Object { $_.Object -like '*on SQL03' }).Count -eq 0) 'No duplicate per-database noise for the disconnected replica'
Assert ((Find $i 'Warning' '*MB of changes waiting to be SENT to SQL02*').Count -eq 1) 'Send queue 200 MB -> Warning'
Assert ((Find $i 'Warning' 'SalesDB on SQL02 is SYNCHRONIZING*').Count -eq 1) 'Sync-commit replica not SYNCHRONIZED -> Warning'
Assert ((Find $i 'Warning' 'HRDB is not joined*').Count -eq 1) 'Database not joined on secondary -> Warning'
Assert ((Find $i 'Warning' 'HRDB is not joined*')[0].Queries[1].Sql -match 'SET HADR AVAILABILITY GROUP = \[AG_Sales\]') 'Join fix query is built correctly'
Assert ((Find $i 'Warning' 'Cluster member is DOWN*').Count -eq 1) 'Cluster node down -> Warning'
Assert (@($i | Where-Object { $_.Title -like '*Listener*no ONLINE*' }).Count -eq 0) 'Multi-subnet listener with one IP online is not an issue'
Assert (@($i | Where-Object { $_.Title -like '*behind for SalesDB*' }).Count -eq 0) 'Lag issue suppressed when a more specific issue exists'
Assert (@($i | Where-Object { $_.Title -like 'AG_Sales reports*' }).Count -eq 0) 'Generic NOT_HEALTHY not added when specific causes found'
$tab = Get-HAAgTables -Data $agData -Server 'SQL01'
Assert ($tab['Databases'].Count -eq 5 -and $tab['Replicas'].Count -eq 3) 'AG grid tables built'
Assert ((@($tab['Databases'] | Where-Object { $_.Replica -eq 'SQL02' -and $_.Database -eq 'SalesDB' })[0].'Est. Data Loss (s)') -eq 120) 'Estimated data loss computed from last_commit_time (120 s)'

Write-Host "`n=== AG: connected to SECONDARY ===" -ForegroundColor Cyan
$agSec = @{
    Groups    = @(Row $cG @{ group_id = $g; ag_name = 'AG_Sales'; primary_replica = 'SQL01' })
    Replicas  = @(
        (Row $cR @{ group_id = $g; replica_id = $r1; replica_server_name = 'SQL01' }),
        (Row $cR @{ group_id = $g; replica_id = $r2; replica_server_name = 'SQL02'; is_local = $true; role_desc = 'SECONDARY'; operational_state_desc = 'ONLINE'; connected_state_desc = 'CONNECTED' })
    )
    Databases = @(
        (Row $cD @{ group_id = $g; replica_id = $r1; replica_server_name = 'SQL01'; group_database_id = $dbS; database_name = 'SalesDB'; is_database_joined = $true }),
        (Row $cD @{ group_id = $g; replica_id = $r2; replica_server_name = 'SQL02'; availability_mode_desc = 'ASYNCHRONOUS_COMMIT'; group_database_id = $dbS; database_name = 'SalesDB'; is_database_joined = $true; is_local = $true; synchronization_state_desc = 'SYNCHRONIZING'; synchronization_health_desc = 'HEALTHY'; is_suspended = $false; redo_queue_size = 2097152; redo_rate = 1024; log_send_queue_size = 0 })
    )
    Listeners = @(); Cluster = @(); Members = @()
    Endpoints = @(Row $cE @{ name = 'Hadr_endpoint'; state_desc = 'STARTED'; port = 5022 })
    RedoBlocking = @([pscustomobject]@{ session_id = 41; database_name = 'SalesDB'; command = 'DB STARTUP'; blocking_session_id = 87; wait_type = 'LCK_M_SCH_M'; wait_time = 600000; wait_resource = '' })
}
$i = Get-HAAgIssues -Data $agSec -Server 'SQL02' -Thresholds $T; Show $i
$redir = Find $i 'Info' 'Connected to a SECONDARY*'
Assert ($redir.Count -eq 1 -and $redir[0].ConnectTo -eq 'SQL01') 'Secondary detected; points to primary SQL01'
Assert ((Find $i 'Critical' '*APPLIED on SQL02*').Count -eq 1) 'Redo queue 2 GB -> Critical'
Assert ((Find $i 'Critical' 'Redo for SalesDB is BLOCKED by session 87').Count -eq 1) 'Redo blocked by reader detected'
Assert (@($i | Where-Object { $_.Severity -eq 'Critical' -and $_.Title -like '*RESOLVING*' }).Count -eq 0) 'Secondary is not mistaken for RESOLVING'

Write-Host "`n=== AG: endpoint stopped + RESOLVING ===" -ForegroundColor Cyan
$agRes = @{
    Groups = @(Row $cG @{ group_id = $g; ag_name = 'AG_X'; primary_replica = $null })
    Replicas = @(Row $cR @{ group_id = $g; replica_id = $r1; replica_server_name = 'SQL01'; is_local = $true; role_desc = 'RESOLVING'; operational_state_desc = 'PENDING' })
    Databases = @(); Listeners = @(); Cluster = @([pscustomobject]@{ cluster_name = 'CLU1'; quorum_type_desc = 'NODE_MAJORITY'; quorum_state_desc = 'FORCED_QUORUM' }); Members = @(); RedoBlocking = @()
    Endpoints = @(Row $cE @{ name = 'Hadr_endpoint'; state_desc = 'STOPPED'; port = 5022 })
}
$i = Get-HAAgIssues -Data $agRes -Server 'SQL01' -Thresholds $T; Show $i
Assert ((Find $i 'Critical' 'AG_X has no primary*').Count -eq 1) 'RESOLVING -> Critical'
Assert ((Find $i 'Critical' 'HADR endpoint is STOPPED').Count -eq 1) 'Stopped endpoint -> Critical'
Assert ((Find $i 'Critical' '*quorum is FORCED_QUORUM').Count -eq 1) 'Forced quorum -> Critical'

# ------------------------------------------------------------------ LOG SHIPPING
$cP = 'primary_id', 'primary_database', 'backup_directory', 'backup_share', 'backup_job_id', 'monitor_server', 'last_backup_file', 'last_backup_date', 'backup_threshold', 'threshold_alert_enabled', 'minutes_since_backup', 'state_desc', 'recovery_model_desc'
$cS = 'secondary_id', 'primary_server', 'primary_database', 'backup_source_directory', 'backup_destination_directory', 'copy_job_id', 'restore_job_id', 'monitor_server', 'secondary_database', 'restore_delay', 'restore_mode', 'disconnect_users', 'restore_threshold', 'threshold_alert_enabled', 'last_copied_file', 'last_restored_file', 'last_restored_latency', 'minutes_since_copy', 'minutes_since_restore', 'state_desc', 'is_in_standby'
$cJ = 'job_id', 'job_name', 'enabled', 'category', 'run_status', 'run_datetime', 'last_message', 'minutes_since_last_run', 'is_running'

Write-Host "`n=== LS: PRIMARY ===" -ForegroundColor Cyan
$bj = [guid]::NewGuid(); $pid1 = [guid]::NewGuid()
$lsP = @{
    Primary = @(Row $cP @{ primary_id = $pid1; primary_database = 'SalesDB'; backup_directory = 'D:\LS\Sales'; backup_share = '\\SQL01\LS\Sales'; backup_job_id = $bj; backup_threshold = 60; minutes_since_backup = 95; state_desc = 'ONLINE'; recovery_model_desc = 'FULL' })
    PrimarySecondaries = @([pscustomobject]@{ primary_id = $pid1; secondary_server = 'SQL02'; secondary_database = 'SalesDB' })
    Secondary = @(); MonitorPrimary = @(); MonitorSecondary = @(); Errors = @()
    OtherLogBackups = @(
        [pscustomobject]@{ database_name = 'SalesDB'; backup_finish_date = $now.AddHours(-3); is_copy_only = $false; physical_device_name = 'D:\LS\Sales\SalesDB_20261002.trn'; device_type = 2 },
        [pscustomobject]@{ database_name = 'SalesDB'; backup_finish_date = $now.AddHours(-2); is_copy_only = $false; physical_device_name = '\\backupsrv\nightly\SalesDB_LOG.trn'; device_type = 2 },
        [pscustomobject]@{ database_name = 'SalesDB'; backup_finish_date = $now.AddHours(-1); is_copy_only = $true; physical_device_name = 'E:\adhoc\copyonly.trn'; device_type = 2 }
    )
    Jobs = @(Row $cJ @{ job_id = $bj; job_name = 'LSBackup_SalesDB'; enabled = $true; run_status = 0; run_datetime = $now.AddMinutes(-15); last_message = 'Executed as user: NT SERVICE\SQLSERVERAGENT. The step failed.'; is_running = 0 })
}
$i = Get-HALogShippingIssues -Data $lsP -Server 'SQL01' -Thresholds $T -AgentStatus 'Running'; Show $i
Assert ((Find $i 'Critical' 'No log backup for SalesDB*').Count -eq 1) 'Backup older than threshold -> Critical'
Assert ((Find $i 'Critical' 'Last run FAILED: LSBackup_SalesDB').Count -eq 1) 'Failed backup job -> Critical'
Assert ((Find $i 'Warning' '1 log backup(s) of SalesDB taken OUTSIDE*').Count -eq 1) 'Outside log backup detected (copy-only ignored)'
$ri = Find $i 'Info' 'Copy/restore status of SalesDB lives on secondary SQL02'
Assert ($ri.Count -eq 1 -and $ri[0].ConnectTo -eq 'SQL02') 'Primary points to the secondary for copy/restore status'

Write-Host "`n=== LS: SECONDARY ===" -ForegroundColor Cyan
$copyJobId = [guid]::NewGuid(); $restJobId = [guid]::NewGuid()
$lsS = @{
    Primary = @(); PrimarySecondaries = @(); MonitorPrimary = @(); MonitorSecondary = @(); OtherLogBackups = @()
    Secondary = @(
        (Row $cS @{ secondary_id = [guid]::NewGuid(); primary_server = 'SQL01'; primary_database = 'SalesDB'; backup_source_directory = '\\SQL01\LS\Sales'; backup_destination_directory = 'E:\LScopy'; copy_job_id = $copyJobId; restore_job_id = $restJobId; secondary_database = 'SalesDB'; restore_delay = 0; restore_mode = 1; disconnect_users = $false; restore_threshold = 45; minutes_since_copy = 5; minutes_since_restore = 200; state_desc = 'ONLINE'; is_in_standby = $true }),
        (Row $cS @{ secondary_id = [guid]::NewGuid(); primary_server = 'SQL01'; primary_database = 'HRDB'; secondary_database = 'HRDB'; restore_delay = 0; restore_threshold = 45; minutes_since_copy = 400; minutes_since_restore = 400; state_desc = 'ONLINE'; is_in_standby = $false }),
        (Row $cS @{ secondary_id = [guid]::NewGuid(); primary_server = 'SQL01'; primary_database = 'Ops'; secondary_database = 'Ops'; restore_delay = 240; restore_threshold = 45; minutes_since_copy = 10; minutes_since_restore = 250; state_desc = 'RESTORING'; is_in_standby = $false })
    )
    Errors = @([pscustomobject]@{ agent_type = 2; database_name = 'SalesDB'; log_time = $now.AddMinutes(-3); message = 'Exclusive access could not be obtained because the database is in use.'; minutes_ago = 3 })
    Jobs = @(
        (Row $cJ @{ job_id = $copyJobId; job_name = 'LSCopy_SQL01_SalesDB'; enabled = $true; run_status = 1; is_running = 0 }),
        (Row $cJ @{ job_id = $restJobId; job_name = 'LSRestore_SQL01_SalesDB'; enabled = $false; run_status = 1; is_running = 0 })
    )
}
$i = Get-HALogShippingIssues -Data $lsS -Server 'SQL02' -Thresholds $T -AgentStatus 'Running'; Show $i
$rest = Find $i 'Critical' 'SalesDB last restored*'
Assert ($rest.Count -eq 1 -and $rest[0].Explanation -like '*files ARE arriving*' -and -not $rest[0].ConnectTo) 'Restore late but copies arriving -> restore-side problem, no redirect'
Assert ((Find $i 'Critical' 'SQL Agent job is DISABLED: LSRestore_SQL01_SalesDB').Count -eq 1) 'Disabled restore job -> Critical'
Assert ((Find $i 'Critical' 'Secondary HRDB was RECOVERED*').Count -eq 1) 'Recovered secondary detected'
$hr = Find $i 'Critical' 'HRDB last restored*'
Assert ($hr.Count -eq 1 -and $hr[0].ConnectTo -eq 'SQL01') 'Copy and restore both late -> points upstream to primary'
Assert ((Find $i 'Critical' 'Ops last restored*').Count -eq 0) 'Configured restore delay is respected'
Assert ((Find $i 'Warning' '*Restore message(s) for SalesDB*')[0].Explanation -like '*Users are connected*') 'Error text translated to plain English'
$sp = Find $i 'Info' 'This server is a log shipping secondary of SQL01'; Assert ($sp.Count -eq 1 -and $sp[0].ConnectTo -eq 'SQL01') 'Secondary points to its primary (one message per primary)'

Write-Host "`n=== LS: SQL Agent stopped ===" -ForegroundColor Cyan
$i = Get-HALogShippingIssues -Data $lsS -Server 'SQL02' -Thresholds $T -AgentStatus 'Stopped'
Assert ((Find $i 'Critical' 'SQL Server Agent is not running').Count -eq 1) 'Agent stopped -> Critical'

# ------------------------------------------------------------------ REPLICATION
$cDA = 'agent_id', 'agent_name', 'job_id', 'local_job', 'publisher_db', 'publication', 'subscriber_db', 'subscription_type', 'publisher', 'subscriber', 'runstatus', 'last_time', 'minutes_since_history', 'comments', 'delivery_latency', 'current_delivery_latency', 'error_id', 'error_code', 'error_text', 'xact_seqno', 'command_id', 'min_status'
$cLR = 'agent_id', 'agent_name', 'job_id', 'local_job', 'publisher_db', 'publisher', 'runstatus', 'last_time', 'minutes_since_history', 'comments', 'delivery_latency', 'error_id', 'error_code', 'error_text'
$cDB = 'name', 'is_published', 'is_merge_published', 'is_distributor', 'is_cdc_enabled', 'log_reuse_wait_desc', 'state_desc'

Write-Host "`n=== REPL: healthy local topology (rows captured from a real distributor) ===" -ForegroundColor Cyan
$rpOk = @{
    Databases = @((Row $cDB @{ name = 'AdventureWorks2022'; is_published = $true; is_merge_published = $false; is_distributor = $false; is_cdc_enabled = $false; log_reuse_wait_desc = 'NOTHING'; state_desc = 'ONLINE' }), (Row $cDB @{ name = 'distribution'; is_published = $false; is_merge_published = $false; is_distributor = $true; is_cdc_enabled = $false; log_reuse_wait_desc = 'NOTHING'; state_desc = 'ONLINE' }))
    LogUsed = @([pscustomobject]@{ name = 'AdventureWorks2022'; log_used_pct = 12 })
    RemoteDistributor = @([pscustomobject]@{ name = 'repl_distributor'; data_source = 'HLMM' })
    Distributors = @(@{
            Name = 'distribution'
            Distribution = @(Row $cDA @{ agent_id = 10; agent_name = 'HLMM-AdventureWorks2022-Adventureworkstbls-HLMM\V2025-10'; local_job = $true; publisher_db = 'AdventureWorks2022'; publication = 'Adventureworkstbls'; subscriber_db = 'Adventureworksrepl'; subscription_type = 0; publisher = 'HLMM'; subscriber = 'HLMM\V2025'; runstatus = 4; minutes_since_history = 1; comments = 'No replicated transactions are available.'; delivery_latency = 0; current_delivery_latency = 0; error_id = 0; min_status = 2 })
            Pending = @([pscustomobject]@{ agent_id = 10; pending_cmds = 0 })
            LogReaders = @(Row $cLR @{ agent_id = 2; agent_name = 'HLMM-AdventureWorks2022-2'; publisher_db = 'AdventureWorks2022'; publisher = 'HLMM'; runstatus = 4; minutes_since_history = 1; comments = 'No replicated transactions are available.'; delivery_latency = 0; error_id = 0 })
            Snapshots = @(); Merge = @(); Errors = @(); CmdRows = @([pscustomobject]@{ cmd_rows = 1200 })
        })
    Jobs = @(
        (Row $cJ @{ job_id = [guid]::NewGuid(); job_name = 'Distribution clean up: distribution'; enabled = $true; category = 'REPL-Distribution Cleanup'; run_status = 1; is_running = 0 }),
        (Row $cJ @{ job_id = [guid]::NewGuid(); job_name = 'Expired subscription clean up'; enabled = $false; category = 'REPL-Subscription Cleanup'; is_running = 0 })
    )
    Subscriptions = @()
}
$i = Get-HAReplicationIssues -Data $rpOk -Server 'HLMM' -Thresholds $T -AgentStatus 'Running'; Show $i
Assert (@($i | Where-Object { $_.Severity -ne 'Info' }).Count -eq 0) 'Healthy topology produces no warnings/criticals'
Assert ((Find $i 'Info' '*DISABLED: Expired subscription clean up').Count -eq 1) 'Disabled expired-subscription cleanup is only Info'
$tab = Get-HAReplicationTables -Data $rpOk -Server 'HLMM' -Thresholds $T
Assert ($tab['Agents'].Count -eq 2 -and @($tab['Agents'] | Where-Object { $_.Health -ne 'OK' }).Count -eq 0) 'Agents grid built, all OK'

Write-Host "`n=== REPL: distributor with failures ===" -ForegroundColor Cyan
$rpBad = @{
    Databases = @((Row $cDB @{ name = 'distribution'; is_distributor = $true; log_reuse_wait_desc = 'NOTHING'; state_desc = 'ONLINE' }))
    LogUsed = @(); RemoteDistributor = @(); Subscriptions = @(); Jobs = @()
    Distributors = @(@{
            Name = 'distribution'
            Distribution = @(
                (Row $cDA @{ agent_id = 21; publisher_db = 'Sales'; publication = 'SalesPub'; subscriber_db = 'SalesRpt'; subscription_type = 0; publisher = 'SQL01'; subscriber = 'RPT01'; runstatus = 6; minutes_since_history = 2; error_id = 77; error_code = '20598'; error_text = 'The row was not found at the Subscriber when applying the replicated UPDATE command for Table ''[dbo].[Orders]''.'; xact_seqno = '0x0000002A000001E8000300000000'; command_id = 1; min_status = 2 }),
                (Row $cDA @{ agent_id = 22; publisher_db = 'Sales'; publication = 'SalesPub'; subscriber_db = 'SalesDW'; subscription_type = 0; publisher = 'SQL01'; subscriber = 'DW01'; runstatus = 3; minutes_since_history = 1; current_delivery_latency = 420000; min_status = 2 }),
                (Row $cDA @{ agent_id = 23; publisher_db = 'Sales'; publication = 'SalesPub'; subscriber_db = 'Old'; subscription_type = 0; publisher = 'SQL01'; subscriber = 'OLD01'; runstatus = 2; minutes_since_history = 9000; min_status = 0 })
            )
            Pending = @([pscustomobject]@{ agent_id = 22; pending_cmds = 150000 })
            LogReaders = @(Row $cLR @{ agent_id = 3; publisher_db = 'Sales'; publisher = 'SQL01'; runstatus = 2; minutes_since_history = 45 })
            Snapshots = @(); Merge = @(); Errors = @(); CmdRows = @()
        })
}
$i = Get-HAReplicationIssues -Data $rpBad -Server 'DIST01' -Thresholds $T -AgentStatus 'Running'; Show $i
$f = Find $i 'Critical' 'Distribution Agent FAILED*SalesRpt'
Assert ($f.Count -eq 1 -and $f[0].Explanation -like '*missing a row*') 'Error 20598 explained in plain English'
Assert (@($f[0].Queries | Where-Object { $_.Sql -like '*sp_browsereplcmds*0x0000002A000001E8000300000000*' }).Count -eq 1) 'sp_browsereplcmds suggestion carries the failing xact_seqno'
Assert ((Find $i 'Critical' '150,000 commands waiting*').Count -eq 1) 'Backlog 150k -> Critical'
Assert ((Find $i 'Critical' 'Delivery latency 420 s*').Count -eq 1) 'Latency 420 s -> Critical'
$inact = Find $i 'Critical' 'Subscription is INACTIVE*'
Assert ($inact.Count -eq 1 -and $inact[0].Queries[0].Sql -like '*sp_reinitsubscription*') 'Inactive subscription -> reinit suggestion'
Assert ((Find $i 'Warning' 'Log Reader for SQL01.Sales is STOPPED').Count -eq 1) 'Stopped log reader -> Warning'

Write-Host "`n=== REPL: publisher with remote distributor + leftover marker; subscriber ===" -ForegroundColor Cyan
$rpPub = @{
    Databases = @(
        (Row $cDB @{ name = 'Sales'; is_published = $true; is_merge_published = $false; is_distributor = $false; is_cdc_enabled = $false; log_reuse_wait_desc = 'REPLICATION'; state_desc = 'ONLINE' }),
        (Row $cDB @{ name = 'RestoredCopy'; is_published = $false; is_merge_published = $false; is_distributor = $false; is_cdc_enabled = $false; log_reuse_wait_desc = 'REPLICATION'; state_desc = 'ONLINE' })
    )
    LogUsed = @([pscustomobject]@{ name = 'Sales'; log_used_pct = 85 }, [pscustomobject]@{ name = 'RestoredCopy'; log_used_pct = 60 })
    RemoteDistributor = @([pscustomobject]@{ name = 'repl_distributor'; data_source = 'DIST01' })
    Distributors = @(); Jobs = @()
    Subscriptions = @([pscustomobject]@{ subscription_db = 'RefData'; publisher = 'HQSQL'; publisher_db = 'Ref'; publication = 'RefPub'; subscription_type = 1; update_mode = 0; distribution_agent = 'x'; last_sync_time = $now.AddHours(-5); minutes_since_sync = 300 })
}
$i = Get-HAReplicationIssues -Data $rpPub -Server 'SQL01' -Thresholds $T -AgentStatus 'Running'; Show $i
$lg = Find $i 'Warning' 'Sales log is 85% full*'
Assert ($lg.Count -eq 1 -and $lg[0].ConnectTo -eq 'DIST01') 'Publisher log held by replication -> points to remote distributor'
Assert ((Find $i 'Warning' 'RestoredCopy log is held by REPLICATION, but the database is not published').Count -eq 1) 'Leftover replication marker detected'
Assert ((Find $i 'Info' 'This publisher uses remote distributor DIST01')[0].ConnectTo -eq 'DIST01') 'Publisher redirects to distributor'
Assert ((Find $i 'Warning' 'Subscriber RefData last received data*')[0].ConnectTo -eq 'HQSQL') 'Stale subscriber points to publisher'

Write-Host "`n=== Core: read-only guard ===" -ForegroundColor Cyan
Assert (Test-HAReadOnlySql "SELECT backup_finish_date, restore_date FROM msdb.dbo.backupset WHERE type = 'L'") 'Guard allows SELECT with backup/restore column names'
Assert (Test-HAReadOnlySql "SELECT 1 FROM sys.dm_exec_requests WHERE command IN (N'DB STARTUP', N'RESTORE DATABASE')") 'Guard ignores keywords inside string literals'
Assert (-not (Test-HAReadOnlySql 'SELECT 1; DROP TABLE x')) 'Guard blocks DROP'
Assert (-not (Test-HAReadOnlySql 'EXEC sp_who2')) 'Guard blocks EXEC'
Assert (-not (Test-HAReadOnlySql 'SELECT * INTO #t FROM sys.objects')) 'Guard blocks SELECT INTO'
Assert (-not (Test-HAReadOnlySql "SELECT 1 /* x */ ; UPDATE t SET a = 1")) 'Guard blocks UPDATE after a comment'
Assert ((ConvertTo-HASqlIdentifier 'a]b') -eq '[a]]b]' -and (ConvertTo-HASqlLiteral "O'Neil") -eq "N'O''Neil'") 'Identifier/literal escaping'
$txt = ConvertTo-HAIssueText -Issue $f[0]
Assert ($txt -like '*VERIFY - read-only*' -and $txt -like '*Further reading*') 'Issue renders to text (copy to clipboard)'

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
