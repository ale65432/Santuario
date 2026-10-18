@echo off
rem Compila Santuario.exe (el lanzador con boveda cifrada). Solo hace falta el .NET Framework que ya trae Windows.
set "CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
"%CSC%" /nologo /target:exe /optimize+ /out:"%~dp0Santuario.exe" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "%~dp0app\launcher\Santuario.cs"
if errorlevel 1 ( echo   Fallo la compilacion. & pause & exit /b 1 )
echo   Listo: Santuario.exe
pause