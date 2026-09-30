@echo off
REM =====================================================================
REM  Simcom WebUI - Deploy to SIM8260 Module (Windows)
REM  Need ADB enabled: AT+CUSBCFG=usbadb,1
REM  adb.exe can be placed in the same folder as this .bat
REM =====================================================================

setlocal
set "ADB=%~dp0adb.exe"
if not exist "%ADB%" set "ADB=adb"

echo ==============================================
echo   Simcom WebUI Deploy Tool
echo   Target: SIM8260 (SDX62)
echo ==============================================
echo.

REM Check adb
"%ADB%" version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] adb.exe not found.
    echo Put adb.exe/AdbWinApi.dll/AdbWinUsbApi.dll in this folder,
    echo or install Android Platform Tools and add to PATH.
    pause
    exit /b 1
)

REM Check device
echo [1/5] Checking device...
"%ADB%" devices
echo.

REM Restart adbd as root (install requires write to /usrdata)
echo [2/5] Switching to root...
"%ADB%" root 2>nul
if errorlevel 1 (
    echo [WARN] adb root failed, trying anyway...
) else (
    "%ADB%" wait-for-device
    echo   OK - running as root
)
echo.

REM Push only files needed on the module (skip adb.exe / .bat / .md docs)
echo [3/5] Pushing to /tmp/simcom-webui ...
"%ADB%" shell "rm -rf /tmp/simcom-webui && mkdir -p /tmp/simcom-webui"
if errorlevel 1 goto :push_fail

"%ADB%" push "%~dp0www" /tmp/simcom-webui/www
if errorlevel 1 goto :push_fail

"%ADB%" push "%~dp0cgi-bin" /tmp/simcom-webui/cgi-bin
if errorlevel 1 goto :push_fail

"%ADB%" push "%~dp0systemd" /tmp/simcom-webui/systemd
if errorlevel 1 goto :push_fail

if exist "%~dp0socat-at-bridge" (
    "%ADB%" push "%~dp0socat-at-bridge" /tmp/simcom-webui/socat-at-bridge
)
if exist "%~dp0install.sh" (
    "%ADB%" push "%~dp0install.sh" /tmp/simcom-webui/install.sh
)
if exist "%~dp0uninstall.sh" (
    "%ADB%" push "%~dp0uninstall.sh" /tmp/simcom-webui/uninstall.sh
)
REM at-runenv.sh 是运行时目录解析器：所有 CGI / 桥脚本都会 source 它来把
REM 日志/锁/心跳/临时文件落到内存 fs。**必须推送**，否则 install.sh 装不到它，
REM 全部 CGI 会退回 /tmp（可能是 NAND）→ 持续磨损闪存。
if exist "%~dp0at-runenv.sh" (
    "%ADB%" push "%~dp0at-runenv.sh" /tmp/simcom-webui/at-runenv.sh
)
if exist "%~dp0README.md" (
    "%ADB%" push "%~dp0README.md" /tmp/simcom-webui/README.md
)

goto :push_ok

:push_fail
echo [ERROR] Push failed. Check USB connection and ADB.
echo Tip: AT+CUSBCFG=usbadb,1  to enable ADB
pause
exit /b 1

:push_ok
echo   Push complete.

REM Install
echo [4/5] Running install script...
"%ADB%" shell "chmod +x /tmp/simcom-webui/install.sh && sh /tmp/simcom-webui/install.sh"
if errorlevel 1 (
    echo [WARNING] Install script had issues, see output above.
)

REM Done
echo.
echo [5/5] Done!
echo ==============================================
echo  Visit: http://192.168.225.1:8888/
echo  Default: admin / admin
echo ==============================================
echo.
endlocal
pause
