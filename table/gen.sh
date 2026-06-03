#!/bin/bash
set -e
cd "$(dirname "$0")"
LUBAN="tools/Luban/Luban.dll"
CLIENT_PKG="../../LeagueOfPhysical-MasterData-Client/Runtime.Generated"
SCRATCH="_gen_scratch"

echo "[gen] target=client -> MasterData-Client package"
rm -rf "$CLIENT_PKG/Scripts/MasterData" "$CLIENT_PKG/StreamingAssets/MasterData"
dotnet "$LUBAN" -t client -c cs-bin -d bin --conf luban.conf \
  -x outputCodeDir="$CLIENT_PKG/Scripts/MasterData" \
  -x outputDataDir="$CLIENT_PKG/StreamingAssets/MasterData"

echo "[gen] target=server -> scratch (wired in Slice γ)"
rm -rf "$SCRATCH/server"
dotnet "$LUBAN" -t server -c cs-bin -d bin --conf luban.conf \
  -x outputCodeDir="$SCRATCH/server/cs" \
  -x outputDataDir="$SCRATCH/server/bytes"

echo "[done]"
