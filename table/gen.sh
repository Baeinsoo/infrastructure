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
# rm -rf 직후엔 git이 추적하던 .meta가 "삭제됨"으로 남는다 — .meta만 골라 git에서
# 원래대로 되돌린다. (.cs/.bytes처럼 Luban이 진짜로 지우려던 파일까지 되살리면 안
# 되므로 .meta로 좁힌다 — 나중에 테이블/빈을 진짜 삭제하는 변경이 와도 옛 생성 코드가
# 조용히 되돌아오지 않게.) 지워진 .meta가 없으면(정상 케이스) 아무 것도 하지 않는다.
restore_deleted_meta() {
  local repo_root="$1"
  # 변수에 담지 않고 바로 파이프로 넘긴다 — command substitution($(...))은 NUL
  # 구분자를 못 담아서 파일명들이 한 덩어리로 뭉개진다.
  git -C "$repo_root" diff --name-only -z --diff-filter=D -- Runtime.Generated \
    | grep -z '\.meta$' \
    | xargs -0 -r git -C "$repo_root" checkout --
}

# dotnet(Luban)이 rm -rf 다음에 죽어도(예: 이번에 실제로 겪은 .NET 런타임 버전
# 불일치) .meta 복원은 반드시 돌아야 한다 — 안 그러면 실패할 때마다 수작업
# git checkout이 다시 필요해져서, 애초에 이 함수로 없애려던 그 수작업이 되돌아온다.
# 그래서 각 dotnet 호출 뒤에 개별로 부르는 대신, 스크립트가 성공하든 실패하든
# 끝날 때 한 번 trap으로 묶어서 both 저장소를 복원한다.
trap 'restore_deleted_meta "$CLIENT_REPO"; restore_deleted_meta "$SERVER_REPO"' EXIT

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

echo "[gen] target=matchmaking -> lop-backend/apps/matchmaking-server"
rm -rf "$MM_PKG/src/masterdata" "$MM_PKG/master_data"
dotnet "$LUBAN" -t matchmaking -c typescript-json -d json --conf luban.conf \
  -x outputCodeDir="$MM_PKG/src/masterdata" \
  -x outputDataDir="$MM_PKG/master_data"

echo "[done]"
