@echo off
%SystemRoot%\System32\chcp.com 65001 >nul
title Santuario
rem El encabezado se adapta al tamano real de la ventana (no se fuerza el tamano: confunde a Windows Terminal)
call "%~dp0app\env.bat"
rem Integridad: compara los scripts de la USB con la huella aprobada en este PC y comprueba la firma de Ollama
call "%SANT%app\verify.bat"
if errorlevel 1 (
  echo.
  echo   Arranque cancelado por la verificacion de integridad.
  pause
  exit /b 1
)

rem Si el agente 24/7 ya esta corriendo, se REUTILIZA su Ollama (no se reinicia). Se comprueba tambien al salir.
set "REUSE="
call :daemon_alive
if not errorlevel 1 set "REUSE=1"

if not defined REUSE (
  rem Reinicia cualquier Ollama previo para usar el de la USB con este entorno
  "%TASKKILL%" /im ollama.exe /f >nul 2>&1
  "%TASKKILL%" /im llama-server.exe /f >nul 2>&1
  start "" /min "%SystemRoot%\System32\cmd.exe" /c ""%SANT%app\serve.bat"" <nul >nul 2>&1
  rem Agente 24/7 INTEGRADO: IA y agente son un solo programa. Arranca en segundo plano unos segundos despues (Ollama ya levantando)
  rem y termina solo cuando esta consola se cierra (comparte el PID de la consola).
  set "SANT_INTEGRADO=1"
  start "Santuario Agente" /min "%SystemRoot%\System32\cmd.exe" /c ""%PING%" -n 9 127.0.0.1 >nul & "%SANT%Santuario-Agente.bat"" <nul >nul 2>&1
)

rem El script muestra la pantalla de arranque mientras Ollama inicia
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%SANT%app\santuario.ps1"

rem Al salir: se detiene el agente integrado y despues Ollama (solo si nadie mas lo usa)
if defined SANT_INTEGRADO call :parar_agente
call :daemon_alive
if errorlevel 1 (
  "%TASKKILL%" /im ollama.exe /f >nul 2>&1
  "%TASKKILL%" /im llama-server.exe /f >nul 2>&1
)
exit /b 0

:parar_agente
echo x> "%SANT%data\agent\QUIT"
set "W=0"
:espera
call :daemon_alive
if errorlevel 1 goto parado
set /a W+=1
if %W% GEQ 15 goto parado
"%PING%" -n 2 127.0.0.1 >nul
goto espera
:parado
if exist "%SANT%data\agent\QUIT" del "%SANT%data\agent\QUIT" >nul 2>&1
exit /b 0

:daemon_alive
rem errorlevel 0 = hay un agente vivo (el pid existe Y ese proceso es de verdad daemon.ps1, no un numero reciclado)
"%PSH%" -NoProfile -Command "$f='%SANT%data\agent\daemon.pid'; if(Test-Path $f){ $p=[int](Get-Content $f); $w=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p) -ErrorAction SilentlyContinue; if($w -and $w.CommandLine -match 'daemon\.ps1'){ exit 0 } }; exit 1"
exit /b %ERRORLEVEL%