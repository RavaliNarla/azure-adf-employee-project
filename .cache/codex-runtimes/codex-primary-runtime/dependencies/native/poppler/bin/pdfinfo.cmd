@echo off
setlocal DisableDelayedExpansion
set "CODEX_ARGS="
:codex_arg_loop
if "%~1"=="" goto codex_run
set CODEX_ARGS=%CODEX_ARGS% "%~1"
shift
goto codex_arg_loop
:codex_run
"%~dp0..\Library\bin\pdfinfo.exe" %CODEX_ARGS%
exit /b %ERRORLEVEL%
