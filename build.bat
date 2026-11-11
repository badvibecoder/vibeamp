@echo off
setlocal
set "ROOT=%~dp0"

if not defined ODIN set "ODIN=odin"
if not exist "%ROOT%bin" mkdir "%ROOT%bin"

set "RES=-resource:%ROOT%res\app.rc"

if /I "%~1"=="release" (
    %ODIN% build "%ROOT%src" -out:"%ROOT%bin\vibeamp.exe" -subsystem:windows %RES% -o:speed
) else (
    %ODIN% build "%ROOT%src" -out:"%ROOT%bin\vibeamp.exe" -subsystem:windows %RES% -debug
)

if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

echo Built %ROOT%bin\vibeamp.exe
