@echo off
rem Entorno portable de Santuario: todo (modelos, claves, logs) vive dentro de la carpeta de la USB.
rem Uso: call env.bat          -> modo 100 por ciento LOCAL (sin salida a internet)
rem      call env.bat online   -> solo para Instalar-Cerebro.bat (descarga de modelos)
set "NoDefaultCurrentDirectoryInExePath=1"
set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PING=%SystemRoot%\System32\ping.exe"
set "TASKKILL=%SystemRoot%\System32\taskkill.exe"
for %%I in ("%~dp0..") do set "SANT=%%~fI\"
set "OLLAMA=%SANT%app\ollama\ollama.exe"
set "OLLAMA_MODELS=%SANT%models"
set "OLLAMA_HOST=127.0.0.1:11434"
set "OLLAMA_MAX_LOADED_MODELS=1"
set "OLLAMA_NUM_PARALLEL=1"
set "OLLAMA_KEEP_ALIVE=10m"
set "OLLAMA_FLASH_ATTENTION=1"
set "OLLAMA_NOHISTORY=1"
set "OLLAMA_NOPRUNE=1"
rem Redirige las carpetas de usuario para no dejar claves ni logs en el PC anfitrion
set "USERPROFILE=%SANT%data\home"
set "LOCALAPPDATA=%SANT%data\local"
set "APPDATA=%SANT%data\roaming"
if not exist "%USERPROFILE%" mkdir "%USERPROFILE%"
if not exist "%LOCALAPPDATA%" mkdir "%LOCALAPPDATA%"
if not exist "%APPDATA%" mkdir "%APPDATA%"

if /i "%~1"=="online" goto :eof

rem --- Modo local: sin funciones de nube y con un "interruptor" de red ---
set "OLLAMA_NO_CLOUD=1"
rem Cualquier intento de Ollama de salir a internet va a un proxy inexistente y falla.
set "HTTP_PROXY=http://127.0.0.1:9"
set "HTTPS_PROXY=http://127.0.0.1:9"
set "ALL_PROXY=http://127.0.0.1:9"
set "NO_PROXY=127.0.0.1,localhost,::1"
