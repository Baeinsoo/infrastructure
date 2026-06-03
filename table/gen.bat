@echo off
setlocal
cd /d %~dp0
set LUBAN=tools\Luban\Luban.dll
set CLIENT_PKG=..\..\LeagueOfPhysical-MasterData-Client\Runtime.Generated
set SCRATCH=_gen_scratch
echo [gen] target=client
if exist "%CLIENT_PKG%\Scripts\MasterData" rmdir /s /q "%CLIENT_PKG%\Scripts\MasterData"
if exist "%CLIENT_PKG%\StreamingAssets\MasterData" rmdir /s /q "%CLIENT_PKG%\StreamingAssets\MasterData"
dotnet %LUBAN% -t client -c cs-bin -d bin --conf luban.conf ^
  -x outputCodeDir=%CLIENT_PKG%\Scripts\MasterData ^
  -x outputDataDir=%CLIENT_PKG%\StreamingAssets\MasterData
echo [gen] target=server -> scratch
if exist %SCRATCH%\server rmdir /s /q %SCRATCH%\server
dotnet %LUBAN% -t server -c cs-bin -d bin --conf luban.conf ^
  -x outputCodeDir=%SCRATCH%\server\cs ^
  -x outputDataDir=%SCRATCH%\server\bytes
echo [done]
