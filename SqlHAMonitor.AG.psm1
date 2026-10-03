#Requires -Version 5.1
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

Set-StrictMode -Version 2.0

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

Export-ModuleMember -Function Get-HAAgData, Get-HAAgIssues, Get-HAAgTables, Get-HAAgReport
