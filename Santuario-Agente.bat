@echo off
%SystemRoot%\System32\chcp.com 65001 >nul
title Santuario - Agente 24/7
rem Agente permanente: tareas programadas + Telegram. Esta ventana es el vigilante: si el agente se cae, lo reinicia (con espera creciente)
rem y si Ollama se cae lo vuelve a levantar. Ollama sigue en MODO LOCAL (sin internet) en su propio proceso; solo el agente habla con Telegram.
rem Para detenerlo: cierra esta ventana, o crea el archivo agent\QUIT.  Para pausarlo: crea agent\STOP.
call "%~dp0app\env.bat" online
rem El agente habla con Telegram: NUNCA arranca si la integridad no esta aprobada (no pregunta; abre Santuario.bat una vez para aprobar).
call "%SANT%app\verify.bat" -NoPrompt
if errorlevel 1 (
  echo.
  echo   Arranque cancelado: la integridad de Santuario no esta aprobada. Abre Santuario.bat una vez y aprueba.
  pause
  exit /b 1
)

echo.
echo   SANTUARIO - AGENTE 24/7
echo   Mantiene el PC despierto mientras corre. Cierra esta ventana para detenerlo.
echo.
set FAILS=0
:loop
"%PSH%" -NoProfile -Command "try{Invoke-RestMethod http://127.0.0.1:11434/api/tags -TimeoutSec 2 | Out-Null; exit 0}catch{exit 1}"
if errorlevel 1 start "" /min "%SystemRoot%\System32\cmd.exe" /c ""%SANT%app\serve.bat"" <nul >nul 2>&1
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%SANT%agent\daemon.ps1"
set RC=%ERRORLEVEL%
if %RC%==0 goto fin
rem 3 = fallo despues de funcionar un buen rato (no cuenta como bucle de arranque); cualquier otro codigo si
if %RC%==3 set FAILS=0
if not %RC%==3 set /a FAILS+=1
if %FAILS% GEQ 8 goto demasiados
set /a WAIT=FAILS*10+5
echo [%TIME%] El agente se detuvo (codigo %RC%). Reintento en %WAIT% s...
"%PING%" -n %WAIT% 127.0.0.1 >nul
goto loop

:demasiados
echo.
echo   El agente fallo 8 veces seguidas nada mas arrancar. Me detengo para no entrar en bucle.
echo   Revisa logs\daemon-*.log y ejecuta este archivo de nuevo cuando lo arregles.
pause
:fin