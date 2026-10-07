@echo off
rem Drift: stop it and remove it from sign-in. History and settings are kept.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0install.ps1" -Uninstall
