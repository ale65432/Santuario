@echo off
chcp 65001 >nul
title Santuario - quitar inicio automatico
rem Uso: Quitar-Inicio-Automatico.bat          -> quita el inicio automatico
rem      Quitar-Inicio-Automatico.bat TODO     -> ademas borra el token de Telegram cifrado y las claves de tareas de ESTE PC
if /i "%~1"=="TODO" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\autostart-remove.ps1" -IncluirSecretos
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\autostart-remove.ps1"
)
echo.
echo   Listo: Santuario ya no arranca solo con Windows.
pause
