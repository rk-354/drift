@echo off
rem Drift: start it now and at every sign-in. No admin rights needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0install.ps1"
