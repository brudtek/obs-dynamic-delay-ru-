@echo off
rem Install the delay control plugin into OBS Studio (asks for administrator rights).
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0installer.ps1"
