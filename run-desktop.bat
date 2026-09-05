@echo off
setlocal
cd /d "%~dp0"
echo Starting Lazer desktop via Gradle runDesktop ...
call gradlew.bat :desktopApp:runDesktop --no-configuration-cache %*
