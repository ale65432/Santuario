@echo off
%SystemRoot%\System32\chcp.com 65001 >nul
title Santuario - configurar Telegram (USA INTERNET)
rem Este script habla con api.telegram.org. Guarda el token cifrado en tu PC (DPAPI), no en la USB.
call "%~dp0app\env.bat" online
rem Maneja el token: no corre si la integridad no esta aprobada (abre Santuario.bat una vez para aprobar).
call "%SANT%app\verify.bat" -NoPrompt
if errorlevel 1 (
  echo.
  echo   Cancelado: la integridad de Santuario no esta aprobada. Abre Santuario.bat una vez y aprueba.
  pause
  exit /b 1
)
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%SANT%agent\setup-telegram.ps1"
pause