@echo off
title GameLoop Doctor Launcher
:: Launches the native Windows WPF Desktop App (auto-elevates via UAC)
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GameLoop-Doctor.ps1"
