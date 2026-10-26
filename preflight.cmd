@echo off
setlocal
cd /d "%~dp0"

echo [1/3] validate data and scripts ...
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\validate.ps1"
if errorlevel 1 goto fail

echo.
echo [2/3] render README.md and docs/data.js ...
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\render.ps1"
if errorlevel 1 goto fail

echo.
echo [3/3] files changed:
git status --short
echo.
echo Done. Nothing listed above means generated files already match your data.
echo Remember: data/*.json is the source, README.md and docs/data.js are generated.
pause
exit /b 0

:fail
echo.
echo Preflight FAILED - fix the problems listed above, then run again.
pause
exit /b 1
