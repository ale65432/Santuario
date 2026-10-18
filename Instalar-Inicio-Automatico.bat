@echo off
chcp 65001 >nul
title Santuario - instalar inicio automatico
echo.
echo   INICIO AUTOMATICO DEL AGENTE (opcional)
echo   ----------------------------------------
echo   Esto hace UN cambio en TU PC (no en la USB):
echo     - Crea el acceso directo "Santuario-Agente" en tu carpeta de Inicio de Windows
echo       (solo tu usuario, sin administrador, sin servicios ni claves del sistema).
echo     - Guarda en tu PC una huella de los scripts del agente. Al iniciar sesion, el agente SOLO arranca
echo       si la USB esta puesta y los scripts no cambiaron desde que lo autorizaste.
echo   Para quitarlo: ejecuta Quitar-Inicio-Automatico.bat.
echo   Nota: el agente solo funciona en este PC con la USB conectada, y mantiene el PC despierto mientras corre.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\autostart-install.ps1" -DryRun
echo.
set /p OK=  Escribe SI para instalarlo (cualquier otra cosa cancela):
if /i not "%OK%"=="SI" (echo   Cancelado. No se cambio nada.& pause & exit /b 0)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\autostart-install.ps1"
echo.
pause
