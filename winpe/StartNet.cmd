@echo off
wpeinit

set SCRIPT_DIR=%~dp0
set LOG_ROOT=%SCRIPT_DIR%logs
if not exist "%LOG_ROOT%" mkdir "%LOG_ROOT%"

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Apply-SecureBootUpdate.ps1" -PayloadPath "%SCRIPT_DIR%payload" -LogRoot "%LOG_ROOT%"
set APPLY_EXIT=%ERRORLEVEL%

echo Apply-SecureBootUpdate.ps1 exit code: %APPLY_EXIT%
if not "%APPLY_EXIT%"=="0" goto :END

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Verify-SecureBootUpdate.ps1" -StatePath "%LOG_ROOT%\SecureBootUpdateState.json" -LogRoot "%LOG_ROOT%"
set VERIFY_EXIT=%ERRORLEVEL%

echo Verify-SecureBootUpdate.ps1 exit code: %VERIFY_EXIT%
exit /b %VERIFY_EXIT%

:END
exit /b %APPLY_EXIT%
