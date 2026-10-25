@echo off
rem Runs ByteCut from source (no build needed). For the .exe, see the dist folder or build\Build.ps1
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\ByteCut.ps1"
