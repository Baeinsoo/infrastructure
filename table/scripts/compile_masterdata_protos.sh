#!/bin/bash
# Slice 2a — compile verification only. Output is /tmp; actual .cs to packages
# comes in Slice 2b once the exporter is rewritten.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TABLE_DIR="$(dirname "$SCRIPT_DIR")"
PROTOC="$TABLE_DIR/tools/protoc-28.2-win64/bin/protoc.exe"
PROTO_PATH="$TABLE_DIR/proto"
INCLUDE_PATH="$TABLE_DIR/tools/protoc-28.2-win64/include"

OUT_PATH="/tmp/lop-masterdata-cs-test"
rm -rf "$OUT_PATH"
mkdir -p "$OUT_PATH"

if [ ! -x "$PROTOC" ]; then
  echo "[error] protoc not found at $PROTOC"
  exit 1
fi

echo "[info] protoc: $($PROTOC --version)"
echo "[info] proto dir: $PROTO_PATH"
echo "[info] output: $OUT_PATH"
echo

PROTOS_COMPILED=0
for proto in "$PROTO_PATH"/*.proto; do
  if [ "$(basename "$proto")" = "lop_options.proto" ]; then
    # lop_options.proto은 다른 .proto가 import해서 자동 컴파일됨.
    # 단독 컴파일도 검증한다.
    echo "[compile] $(basename "$proto") (options definition)"
  else
    echo "[compile] $(basename "$proto")"
  fi
  "$PROTOC" \
    --proto_path="$PROTO_PATH" \
    --proto_path="$INCLUDE_PATH" \
    --csharp_out="$OUT_PATH" \
    "$proto"
  PROTOS_COMPILED=$((PROTOS_COMPILED + 1))
done

echo
echo "[ok] compiled $PROTOS_COMPILED .proto files"
echo "[ok] generated .cs files:"
ls -1 "$OUT_PATH"
