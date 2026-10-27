@echo off
chcp 65001 >nul
title work-hammer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" down all
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" down dashboard
