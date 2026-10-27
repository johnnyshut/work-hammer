@echo off
chcp 65001 >nul
title work-hammer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" up dashboard
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" up all
pause
