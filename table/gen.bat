@echo off
setlocal
cd /d %~dp0
set LUBAN=tools\Luban\Luban.dll
set SCRATCH=_gen_scratch
if exist %SCRATCH% rmdir /s /q %SCRATCH%

for %%T in (client server) do (
  echo [gen] target=%%T
  dotnet %LUBAN% -t %%T -c cs-bin -d bin --conf luban.conf ^
    -x outputCodeDir=%SCRATCH%\%%T\cs ^
    -x outputDataDir=%SCRATCH%\%%T\bytes
)
echo [done]
