#Requires -Version 5.1
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

Set-StrictMode -Version 2.0

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

Export-ModuleMember -Function Get-HAReplicationData, Get-HAReplicationIssues, Get-HAReplicationTables, Get-HAReplicationReport, Get-HAReplErrorHint, Get-HAReplRunStatusText
