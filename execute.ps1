 cd C:\Users\kabda\Downloads\SqlHAMonitor\SqlHAMonitor
 
Get-ChildItem 'C:\Users\kabda\Downloads\SqlHAMonitor' -Recurse | Unblock-File
& 'C:\Users\kabda\Downloads\SqlHAMonitor\SqlHAMonitor\Start-SqlHAMonitor.ps1'

 .\Start-SqlHAMonitor.ps1 -Feature AG -Server SQL01 -RefreshSeconds 10