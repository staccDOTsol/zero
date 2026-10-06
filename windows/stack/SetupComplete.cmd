@echo off
rem Zero (leCore+) - fallback first-boot hook. Placed at %WINDIR%\Setup\Scripts\SetupComplete.cmd.
rem
rem Microsoft disables SetupComplete.cmd when Windows is installed with an OEM product key (the Zero
rem laptops have one in firmware), so the image's autounattend.xml runs the same installer in the
rem specialize pass, which works with OEM keys. This file covers installs without an OEM key and
rem imaging partners who use it in their own task sequence. install.ps1 is idempotent: when the stack
rem is already installed it only re-applies the lockdown.
setlocal
set "LOG=%WINDIR%\Setup\Scripts\lecore-plus-setupcomplete.log"
set "SRC=%WINDIR%\Setup\Scripts\lecore-plus"
if not exist "%SRC%\install.ps1" set "SRC=%~dp0lecore-plus"
if not exist "%SRC%\install.ps1" set "SRC=%~dp0"
echo %DATE% %TIME% SetupComplete: "%SRC%\install.ps1" >> "%LOG%"
"%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SRC%\install.ps1" -Phase setupcomplete >> "%LOG%" 2>&1
echo %DATE% %TIME% exit %ERRORLEVEL% >> "%LOG%"
endlocal
exit /b 0
