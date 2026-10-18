@echo off
rem Verifica la integridad de la USB antes de ejecutar nada. Si existe la copia del verificador en ESTE PC, usa esa (la de la USB podria estar manipulada).
rem Uso: call verify.bat [-NoPrompt]      (requiere env.bat ya cargado)
set "VER=%SANT%app\integrity.ps1"
if exist "%SystemDrive%\Users\%USERNAME%\AppData\Local\Santuario\integrity-run.ps1" set "VER=%SystemDrive%\Users\%USERNAME%\AppData\Local\Santuario\integrity-run.ps1"
set "XARGS="
if defined SANT_STOREDIR set "XARGS=-StoreDir %SANT_STOREDIR%"
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%VER%" -Root "%SANT:~0,-1%" %XARGS% %*
exit /b %ERRORLEVEL%