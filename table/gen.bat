@echo off
setlocal
cd /d %~dp0
set LUBAN=tools\Luban\Luban.dll
set CLIENT_PKG=..\..\LeagueOfPhysical-MasterData-Client\Runtime.Generated
set SERVER_PKG=..\..\LeagueOfPhysical-MasterData-Server\Runtime.Generated
echo [gen] target=client
if exist "%CLIENT_PKG%\Scripts\MasterData" rmdir /s /q "%CLIENT_PKG%\Scripts\MasterData"
if exist "%CLIENT_PKG%\StreamingAssets\MasterData" rmdir /s /q "%CLIENT_PKG%\StreamingAssets\MasterData"
dotnet %LUBAN% -t client -c cs-bin -d bin --conf luban.conf ^
  -x outputCodeDir=%CLIENT_PKG%\Scripts\MasterData ^
  -x outputDataDir=%CLIENT_PKG%\StreamingAssets\MasterData
echo [gen] target=server -> MasterData-Server package
if exist "%SERVER_PKG%\Scripts\MasterData" rmdir /s /q "%SERVER_PKG%\Scripts\MasterData"
if exist "%SERVER_PKG%\StreamingAssets\MasterData" rmdir /s /q "%SERVER_PKG%\StreamingAssets\MasterData"
dotnet %LUBAN% -t server -c cs-bin -d bin --conf luban.conf ^
  -x outputCodeDir=%SERVER_PKG%\Scripts\MasterData ^
  -x outputDataDir=%SERVER_PKG%\StreamingAssets\MasterData
echo [done]
