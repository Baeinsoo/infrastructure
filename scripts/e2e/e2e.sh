#!/bin/bash
set -e

# 이전 룸/파드 정리 — 성공 시엔 조용하지만(stdout만 숨김), 실패하면 stderr가 그대로 보이고
# set -e가 여기서 스크립트를 즉시 멈춘다. 예전엔 2>&1로 에러까지 삼켜서 DELETE 실패가 안 보이고
# 나중에 "Room.matchId" unique 제약 에러로 엉뚱하게 재등장했다.
kubectl exec -i deploy/postgres-deployment -- psql -U postgres -d postgres -c 'DELETE FROM "Room";' >/dev/null
kubectl delete pods -l app=room-pod --force --grace-period=0 >/dev/null
kubectl delete svc -l app=room-service >/dev/null
sleep 1

RESP=$(kubectl exec -i deploy/room-server -- node < /root/trigger.js)
echo "▶ POST /room 응답: $RESP"
ROOMID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
[ -z "$ROOMID" ] && { echo "룸 생성 실패"; exit 1; }
POD=room-pod-$ROOMID
echo "▶ pod: $POD"
echo ""
echo "── 파드 상태 추적 (60초) ──"
for i in $(seq 1 30); do
  P=$(kubectl get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null || echo GONE)
  printf "  %2ds: %s\n" "$((i*2))" "${P:-GONE}"
  [ "$P" = "GONE" ] || [ -z "$P" ] && break
  sleep 2
done
echo ""
echo "── 게임서버 로그 (마지막 60줄) ──"
kubectl logs $POD --tail=60 2>&1 | grep -viE "^\s*$" | tail -50
