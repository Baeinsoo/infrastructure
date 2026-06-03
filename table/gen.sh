#!/bin/bash
# Slice α: generate to scratch dirs for verification (packages wired in β/γ).
set -e
cd "$(dirname "$0")"

LUBAN="tools/Luban/Luban.dll"
SCRATCH="_gen_scratch"
rm -rf "$SCRATCH"

for TARGET in client server; do
  echo "[gen] target=$TARGET"
  dotnet "$LUBAN" \
    -t "$TARGET" \
    -c cs-bin \
    -d bin \
    --conf luban.conf \
    -x outputCodeDir="$SCRATCH/$TARGET/cs" \
    -x outputDataDir="$SCRATCH/$TARGET/bytes"
done

echo "[done] output under $SCRATCH/{client,server}/{cs,bytes}"
