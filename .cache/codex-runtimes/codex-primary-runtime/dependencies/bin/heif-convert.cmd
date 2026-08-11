@echo off
setlocal DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "CODEX_ARGS="
:codex_arg_loop
if "%~1"=="" goto codex_run
set CODEX_ARGS=%CODEX_ARGS% "%~1"
shift
goto codex_arg_loop
:codex_run
"%SCRIPT_DIR%..\native\libheif\libheif\bin\heif-convert.exe" %CODEX_ARGS%
exit /b %ERRORLEVEL%
