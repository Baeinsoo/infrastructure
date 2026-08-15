#!/bin/bash
set -e
cd "$(dirname "$0")"
LUBAN="tools/Luban/Luban.dll"
CLIENT_REPO="../../LeagueOfPhysical-MasterData-Client"
SERVER_REPO="../../LeagueOfPhysical-MasterData-Server"
CLIENT_PKG="$CLIENT_REPO/Runtime.Generated"
SERVER_PKG="$SERVER_REPO/Runtime.Generated"
MM_PKG="../../lop-backend/apps/matchmaking-server"

# Luban이 위 rm -rf로 Scripts/MasterData, StreamingAssets/MasterData를 통째로 지우고
# 다시 만드는데, 유니티가 만든 .meta 파일은 Luban이 새로 만들어주지 않는다. 그래서 이
# rm -rf 직후엔 git이 추적하던 .meta가 그냥 "삭제됨"으로 남는다 — 지워진 것만 골라
# git에서 원래대로 되돌린다. 지워진 게 없으면(정상 케이스) 아무 것도 하지 않는다.
restore_deleted_meta() {
  local repo_root="$1"
  # 변수에 담지 않고 바로 파이프로 넘긴다 — command substitution($(...))은 NUL
  # 구분자를 못 담아서 파일명들이 한 덩어리로 뭉개진다.
  git -C "$repo_root" diff --name-only -z --diff-filter=D -- Runtime.Generated \
    | xargs -0 -r git -C "$repo_root" checkout --
}

echo "[gen] target=client -> MasterData-Client package"
rm -rf "$CLIENT_PKG/Scripts/MasterData" "$CLIENT_PKG/StreamingAssets/MasterData"
dotnet "$LUBAN" -t client -c cs-bin -d bin --conf luban.conf \
  -x outputCodeDir="$CLIENT_PKG/Scripts/MasterData" \
  -x outputDataDir="$CLIENT_PKG/StreamingAssets/MasterData"
restore_deleted_meta "$CLIENT_REPO"

echo "[gen] target=server -> MasterData-Server package"
rm -rf "$SERVER_PKG/Scripts/MasterData" "$SERVER_PKG/StreamingAssets/MasterData"
dotnet "$LUBAN" -t server -c cs-bin -d bin --conf luban.conf \
  -x outputCodeDir="$SERVER_PKG/Scripts/MasterData" \
  -x outputDataDir="$SERVER_PKG/StreamingAssets/MasterData"
restore_deleted_meta "$SERVER_REPO"

echo "[gen] target=matchmaking -> lop-backend/apps/matchmaking-server"
rm -rf "$MM_PKG/src/masterdata" "$MM_PKG/master_data"
dotnet "$LUBAN" -t matchmaking -c typescript-json -d json --conf luban.conf \
  -x outputCodeDir="$MM_PKG/src/masterdata" \
  -x outputDataDir="$MM_PKG/master_data"

echo "[done]"
