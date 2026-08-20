@echo off
rem Publishes iCam.App and places it where it is actually launched from.
rem
rem This script exists because of one bad night: the app was copied out to
rem %DEPLOY% once, improved for twelve hours in the repository, and every
rem launch kept running the morning's binary. Deployment is part of the build
rem or it is a trap.

setlocal
set DEPLOY=%USERPROFILE%\OneDrive\Desktop\iCam-build\windows

taskkill /f /im iCam.exe >nul 2>&1

dotnet publish "%~dp0iCam.App\iCam.App.csproj" -c Release -r win-x64 -p:Platform=x64 --nologo
if errorlevel 1 exit /b 1

robocopy "%~dp0iCam.App\bin\x64\Release\net9.0-windows10.0.19041.0\win-x64\publish" "%DEPLOY%" /mir /njh /njs /ndl /nc /ns >nul
if errorlevel 8 exit /b 1

echo Deployed to %DEPLOY%
endlocal
