#!/bin/bash
set -e
cd "$(dirname "$0")"
LUBAN="tools/Luban/Luban.dll"
CLIENT_PKG="../../LeagueOfPhysical-MasterData-Client/Runtime.Generated"
SERVER_PKG="../../LeagueOfPhysical-MasterData-Server/Runtime.Generated"

echo "[gen] target=client -> MasterData-Client package"
rm -rf "$CLIENT_PKG/Scripts/MasterData" "$CLIENT_PKG/StreamingAssets/MasterData"
dotnet "$LUBAN" -t client -c cs-bin -d bin --conf luban.conf \
  -x outputCodeDir="$CLIENT_PKG/Scripts/MasterData" \
  -x outputDataDir="$CLIENT_PKG/StreamingAssets/MasterData"

echo "[gen] target=server -> MasterData-Server package"
rm -rf "$SERVER_PKG/Scripts/MasterData" "$SERVER_PKG/StreamingAssets/MasterData"
dotnet "$LUBAN" -t server -c cs-bin -d bin --conf luban.conf \
  -x outputCodeDir="$SERVER_PKG/Scripts/MasterData" \
  -x outputDataDir="$SERVER_PKG/StreamingAssets/MasterData"

echo "[done]"
