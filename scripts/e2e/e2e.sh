#!/bin/bash
# 이전 룸/파드 정리
kubectl exec -i deploy/postgres-deployment -- psql -U postgres -d postgres -c 'DELETE FROM "Room";' >/dev/null 2>&1
kubectl delete pods -l app=room-pod --force --grace-period=0 >/dev/null 2>&1
kubectl delete svc -l app=room-service >/dev/null 2>&1
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
