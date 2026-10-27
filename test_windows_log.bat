@echo off
rem Runs tests and writes the output to test_output.log (no pause, so it can run unattended).
rem Optional: put a test path in test_target.txt to run just that (default: test/fork).
cd /d "%~dp0"
set "TARGET=test/fork"
if exist test_target.txt set /p TARGET=<test_target.txt
echo flutter test %TARGET% > test_output.log
call flutter test %TARGET% --dart-define=APP_PATH="C:\Users\ryman\AppData\Roaming\cc.narumi\chaldea" >> test_output.log 2>&1
echo EXIT CODE %ERRORLEVEL% >> test_output.log
