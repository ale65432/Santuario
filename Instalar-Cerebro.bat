@echo off
%SystemRoot%\System32\chcp.com 65001 >nul
title Santuario - instalar cerebro (USA INTERNET)
rem Este es el UNICO script de Santuario que sale a internet (descarga modelos que falten).
call "%~dp0app\env.bat" online
call "%SANT%app\verify.bat" -NoPrompt
if errorlevel 1 (
  echo.
  echo   Cancelado: la integridad de Santuario no esta aprobada. Abre Santuario.bat una vez y aprueba.
  pause
  exit /b 1
)
"%TASKKILL%" /im ollama.exe /f >nul 2>&1
"%TASKKILL%" /im llama-server.exe /f >nul 2>&1
start "" /min "%SystemRoot%\System32\cmd.exe" /c ""%SANT%app\serve.bat" online" <nul >nul 2>&1
"%PING%" -n 5 127.0.0.1 >nul

rem Con internet: descarga lo que falte. Sin internet: solo reconstruye los modelos desde brain.json.
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%SANT%app\setup.ps1" -Pull

"%TASKKILL%" /im ollama.exe /f >nul 2>&1
"%TASKKILL%" /im llama-server.exe /f >nul 2>&1
pause