@echo off
rem Launches the SQL Server HA Monitor (LogShipping). Read-only: it never changes your servers.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-SqlHAMonitor.ps1" -Feature LogShipping %*
