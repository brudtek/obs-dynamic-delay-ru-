@echo off
rem Remove the delay control plugin from OBS Studio (asks for administrator rights).
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0installer.ps1" -Uninstall
