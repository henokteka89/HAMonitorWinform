# Dev helper: captures every collector query (without running it) so each can be syntax-checked on a real instance.
param([string]$OutFile = "$PSScriptRoot/captured-queries.json")
$root = Split-Path $PSScriptRoot
Import-Module "$root/Modules/SqlHAMonitor.Core.psm1", "$root/Modules/SqlHAMonitor.AG.psm1", "$root/Modules/SqlHAMonitor.LogShipping.psm1", "$root/Modules/SqlHAMonitor.Replication.psm1" -Force
$global:Captured = ([System.Collections.Generic.List[object]]::new())
$mock = {
    function Invoke-HACollect {
        param($SqlConnection, $Result, $Label, $Query, [hashtable]$Parameters = @{}, $Timeout, [switch]$Optional)
        $q = $Query; foreach ($k in $Parameters.Keys) { $q = $q -replace [regex]::Escape($k), [string]$Parameters[$k] }
        if (-not (Test-HAReadOnlySql $Query)) { throw "Guard rejected: $Label" }
        $global:Captured.Add([pscustomobject]@{ Label = $Label; Sql = $q })
        $l = ([System.Collections.Generic.List[object]]::new())
        switch -Wildcard ($Label) {
            'Replication databases' { $l.Add([pscustomobject]@{ name = 'distribution'; is_distributor = $true; is_published = $false; is_merge_published = $false; is_cdc_enabled = $false; log_reuse_wait_desc = 'NOTHING'; state_desc = 'ONLINE' }) }
            '*metadata' { $l.Add([pscustomobject]@{ has_replservers = 1 }) }
            'Subscriber database scan' { $l.Add([pscustomobject]@{ name = 'Adventureworksrepl' }); $l.Add([pscustomobject]@{ name = "Odd]Name's" }) }
            'Subscriber table probe' { $l.Add([pscustomobject]@{ db = 'Adventureworksrepl'; oid = 1 }) }
            'Log shipping primary databases' { $l.Add([pscustomobject]@{ backup_job_id = [guid]::NewGuid(); primary_id = [guid]::NewGuid() }) }
        }
        , $l.ToArray()
    }
    function Get-HAJobStatus { param($SqlConnection, $JobIds, $CategoryLike) , @() }
}
foreach ($m in 'SqlHAMonitor.AG', 'SqlHAMonitor.LogShipping', 'SqlHAMonitor.Replication') { . (Get-Module $m) $mock }
$t = Get-HADefaultThresholds
$r = New-HAFeatureResult -Feature AG; [void](& (Get-Module SqlHAMonitor.AG) { param($r) Get-HAAgData -SqlConnection "fake" -Result $r } $r)
$r = New-HAFeatureResult -Feature LS; [void](& (Get-Module SqlHAMonitor.LogShipping) { param($r, $t) Get-HALogShippingData -SqlConnection "fake" -Result $r -Thresholds $t } $r $t)
$r = New-HAFeatureResult -Feature REPL; [void](& (Get-Module SqlHAMonitor.Replication) { param($r, $t) Get-HAReplicationData -SqlConnection "fake" -Result $r -Thresholds $t } $r $t)
$global:Captured | ConvertTo-Json -Depth 3 | Set-Content $OutFile
"Captured $($global:Captured.Count) queries -> $OutFile"
