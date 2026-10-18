@echo off
call "%~dp0env.bat" %1
"%OLLAMA%" serve
