@echo off
rem Builds importable Lazer plugin ZIPs from the example folders next to this file.
rem
rem   build.bat                 -> dist\<plugin-id>-<version>.zip
rem   build.bat <output-dir>    -> <output-dir>\<plugin-id>-<version>.zip
rem
rem The packaging itself lives in build.ps1 (Windows PowerShell 5.1 or newer, no
rem other dependency). build.sh is the bash equivalent for macOS and Linux.

setlocal
set "SCRIPT=%~dp0build.ps1"
if not exist "%SCRIPT%" (
  echo build.ps1 is missing next to build.bat: %SCRIPT%
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
