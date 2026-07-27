@echo off
setlocal
cd /d %~dp0
set LUBAN=tools\Luban\Luban.dll
set CLIENT_PKG=..\..\LeagueOfPhysical-MasterData-Client\Runtime.Generated
set SERVER_PKG=..\..\LeagueOfPhysical-MasterData-Server\Runtime.Generated
set MM_PKG=..\..\LeagueOfPhysical-MatchmakingServer\MatchmakingServer
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
echo [gen] target=matchmaking -^> MatchmakingServer
if exist "%MM_PKG%\src\loaders\generated" rmdir /s /q "%MM_PKG%\src\loaders\generated"
if exist "%MM_PKG%\master_data" rmdir /s /q "%MM_PKG%\master_data"
dotnet %LUBAN% -t matchmaking -c typescript-json -d json --conf luban.conf ^
  -x outputCodeDir=%MM_PKG%\src\loaders\generated ^
  -x outputDataDir=%MM_PKG%\master_data
echo [done]
