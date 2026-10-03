# SqlHAMonitor — AG, Log Shipping & Replication status (PowerShell + WinForms)

A **read-only** desktop monitor for SQL Server high-availability features. Point it at any server; it works out
what that server is (AG primary/secondary, log shipping primary/secondary/monitor, replication
publisher/distributor/subscriber), shows the current status, and explains every problem in plain language
with steps, suggested T-SQL and Microsoft Learn links.

> **Safe for production:** the tool only runs `SELECT` statements. Every batch passes a read-only guard
> (refuses INSERT/UPDATE/DELETE/EXEC/DDL/BACKUP/RESTORE/DBCC/KILL…), runs with `SET LOCK_TIMEOUT 5000`
> and `READ UNCOMMITTED` so it never waits on or holds locks, and connects with `ApplicationIntent=ReadWrite`
> so a listener never silently redirects you. **Suggested queries are only displayed** — labelled
> *VERIFY (read-only)* or *FIX (changes something — review first)* — and are never executed.

---

## Quick start

1. Copy the folder to a Windows PC or jump box that can reach your SQL Servers.
2. If the files came from a download/zip: `Get-ChildItem -Recurse | Unblock-File`
3. Double-click one of:

| Launcher | Shows |
|---|---|
| `Start-SqlHAMonitor.cmd` | All three features (tabs) |
| `Start-AGMonitor.cmd` | Availability Groups only |
| `Start-LogShippingMonitor.cmd` | Log Shipping only |
| `Start-ReplicationMonitor.cmd` | Replication only |

Or from PowerShell:

```powershell
.\Start-SqlHAMonitor.ps1                                   # all features, servers remembered from last time
.\Start-SqlHAMonitor.ps1 -Feature AG -Server SQL01 -RefreshSeconds 10
.\Start-SqlHAMonitor.ps1 -Server SQL01,SQL02,DIST01
```

**Requirements:** Windows PowerShell 5.1 (or PowerShell 7 on Windows), .NET Framework 4.x. No modules to install.
SQL Server 2012 or later. Windows or SQL authentication (passwords are kept in memory only, never saved).

## The window

```
+--------------------+-----------------------------------------------------------------+
| Monitored servers  | [Overview] [Availability Groups] [Log Shipping] [Replication]    |
|  (All servers)     |  summary: "AG_Sales - this server is PRIMARY, health HEALTHY"     |
|  SQL01   Warning   |  +-----------------------------------------------------------+   |
|  SQL02   OK        |  | Replicas | Databases | Listeners | Cluster    (data grids) |   |
|  DIST01  Critical  |  +-----------------------------------------------------------+   |
|                    |  Findings (Critical/Warning/Info) | What is going on / Why it  |   |
|                    |                                   | matters / Steps / Queries /|   |
|                    |                                   | Links  [Connect to SQL03]  |   |
+--------------------+-----------------------------------------------------------------+
 Toolbar: + Add server | Remove | Auto refresh: Off/10s/30s/1m/5m | Refresh now | Show info | Reload thresholds
```

* **Auto refresh** 10 s / 30 s / 1 min / 5 min (or off). Checks run on background threads, one per server, so
  the window never freezes; a slow server doesn't hold up the others.
* **Multiple connections:** add as many servers as you like; click one on the left to filter, or *(All servers)*.
* **Connect to …** button: when a finding says the rest of the picture is on another server, one click adds it
  (re-using Windows authentication; asks for the password with SQL authentication).
* **Copy queries** / **Copy full write-up** put the text on the clipboard for a ticket or a DBA.
* Grids are sortable; rows are coloured by health.

## Where to connect — what each server can see

| Feature | Connected to | What you get | Redirect offered |
|---|---|---|---|
| AG | **Primary** | Every replica & database: connection, sync state, send/redo queues, est. data loss (RPO) & redo time (RTO), listener, quorum | To a secondary when only it can show the cause (redo blocked by a reader, its own connection error, joining a DB, resuming) |
| AG | Secondary | Its own replica: connection to primary, local redo queue, **redo blocked by readers** | → Primary (full view) |
| Log shipping | Primary | Backup job, backup age vs threshold, recovery model, log backups taken *outside* log shipping (chain breakers) | → Each secondary (copy/restore status lives there) |
| Log shipping | Secondary | Copy & restore age vs threshold (honours restore delay), DB state (RESTORING/STANDBY/recovered), copy/restore jobs, error log translated | → Primary when files stop arriving |
| Log shipping | Monitor server | Status of all primaries/secondaries it monitors | → The server with the problem |
| Replication | **Distributor** | All agents (Log Reader, Distribution, Snapshot, Merge): state, latency, **undelivered commands**, error text explained, inactive subscriptions, cleanup jobs, distribution DB size | → Subscriber (blocking), publisher |
| Replication | Publisher | Transaction log held by REPLICATION (% full), leftover replication markers | → Remote distributor |
| Replication | Subscriber | Each subscription, its publisher and when data last arrived | → Publisher (then its distributor) |

## What it detects

**Availability Groups** — no primary / RESOLVING; replica or endpoint down; secondary DISCONNECTED (reported
once, not once per database); data movement SUSPENDED (with the reason in plain words); NOT SYNCHRONIZING;
sync-commit replica not SYNCHRONIZED (no automatic failover); database not joined; log send queue and redo queue
over threshold; estimated data loss (seconds behind); redo blocked by a reader on a readable secondary; listener
with no online IP (multi-subnet aware); cluster quorum not normal / forced; cluster member down.

**Log Shipping** — SQL Agent stopped; backup / copy / restore job disabled or failed (with the job message);
no backup within threshold; copy and restore lag with the *likely side of the problem* (restore vs upstream);
secondary recovered or missing; recovery model SIMPLE; log backups taken outside the log shipping folder in the
last 24 h; recent `log_shipping_monitor_error_detail` messages translated (access denied, missing file, gap in
chain/LSN, users blocking standby restore, disk full…).

**Replication** — agent FAILED / RETRYING with the error translated (20598 row not found, 2627/2601 duplicate key,
547 FK, 18456 login, 21074 inactive subscription, 208/207 schema drift, 8152 truncation, timeouts, deadlocks);
Log Reader stopped/silent; agents silent for too long; undelivered command backlog; delivery latency; inactive
subscriptions (with re-init command for push or pull); cleanup jobs disabled/failing; very large distribution DB;
publisher log held by replication; leftover replication marker on a non-published DB; stale subscriber; merge
conflicts.

## Thresholds

Edit `config.json` and press **Reload thresholds**. Log shipping uses each database's own configured backup/restore
thresholds; the values in the file are only fallbacks.

## Permissions for the monitoring login (read-only)

```sql
GRANT VIEW SERVER STATE TO [DOMAIN\MonitorLogin];
GRANT VIEW ANY DEFINITION TO [DOMAIN\MonitorLogin];
USE msdb;  -- jobs + log shipping tables
CREATE USER [DOMAIN\MonitorLogin] FOR LOGIN [DOMAIN\MonitorLogin];
ALTER ROLE SQLAgentReaderRole ADD MEMBER [DOMAIN\MonitorLogin];
ALTER ROLE db_datareader     ADD MEMBER [DOMAIN\MonitorLogin];
USE distribution;  -- on the distributor only
CREATE USER [DOMAIN\MonitorLogin] FOR LOGIN [DOMAIN\MonitorLogin];
ALTER ROLE replmonitor ADD MEMBER [DOMAIN\MonitorLogin];
```
Missing permissions show up as a finding naming exactly what could not be read.

## Files

```
Start-SqlHAMonitor.ps1          UI (WinForms), background refresh, connection handling
Modules\SqlHAMonitor.Core.psm1  read-only SQL helper + guard, issue model, SQL Agent job status, per-server orchestration
Modules\SqlHAMonitor.AG.psm1            collect -> analyse -> grid tables for Availability Groups
Modules\SqlHAMonitor.LogShipping.psm1   same for Log Shipping
Modules\SqlHAMonitor.Replication.psm1   same for Replication
config.json                     thresholds
Tests\Test-Analyzers.ps1        53 offline tests of the rules (no SQL needed): .\Tests\Test-Analyzers.ps1
Tests\Capture-Queries.ps1       dumps every collector query so it can be syntax-checked on an instance
```
Each module can also be used from a console without the UI, e.g.:
```powershell
Import-Module .\Modules\SqlHAMonitor.Core.psm1, .\Modules\SqlHAMonitor.AG.psm1
$r = Invoke-HAServerCheck -Connection (New-HAConnectionInfo -Server SQL01) -Features AG
$r.Issues | ForEach-Object { ConvertTo-HAIssueText $_ }
```

## Known limits

* Merge replication is monitored from the distributor (agent state/conflicts); the subscriber-side view covers transactional subscriptions.
* Distributed AGs and contained AGs are shown as normal AGs (no special rules yet).
* Times in log shipping use the UTC columns where SQL Server provides them; SQL Agent and replication history are server-local time, compared on the server itself (no client clock skew).
