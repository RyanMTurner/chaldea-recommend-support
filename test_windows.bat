@echo off
rem Double-click to test Chaldea on Windows.
cd /d "%~dp0"
call flutter test test/fork --dart-define=APP_PATH="C:\Users\ryman\AppData\Roaming\cc.narumi\chaldea"
pause
