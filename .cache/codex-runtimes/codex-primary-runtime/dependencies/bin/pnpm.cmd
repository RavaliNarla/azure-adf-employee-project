@echo off
setlocal
set "pnpm_config_pm_on_fail=ignore"
"%~dp0..\node\bin\node.exe" "%~dp0..\node\node_modules\pnpm\bin\pnpm.mjs" %*
exit /b %ERRORLEVEL%
