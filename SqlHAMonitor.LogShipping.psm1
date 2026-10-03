#Requires -Version 5.1
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

Set-StrictMode -Version 2.0

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

Export-ModuleMember -Function Get-HALogShippingData, Get-HALogShippingIssues, Get-HALogShippingTables, Get-HALogShippingReport, Get-HALsErrorHint
