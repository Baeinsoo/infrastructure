# E2E: 게임서버 스폰 확인

`room-server`가 내부 API로 룸을 만들고, 그 룸이 실제로 게임서버 파드를 띄워 60초 이상 살아
있으며 heartbeat가 끊기지 않는지 확인하는 수동 스모크 테스트다. dev(iwinv)에서
GitOps 롤아웃 뒤 손으로 돌려 확인하는 용도 — 자동화된 CI 테스트가 아니다.

이 두 파일은 iwinv(`/root/trigger.js`, `/root/e2e.sh`)에 그대로 올려서 쓰는 스크립트다.
호스트에서 직접 고쳐 쓰지 말고, 여기(레포)를 고친 뒤 다시 올릴 것 — 안 그러면 호스트에만
있는 상태가 또 생긴다(이 커밋 자체가 그런 상태 하나를 되돌린 것).

## 무엇을 증명하는가

1. `POST /internal/room` (room-server 내부 API) 호출 → `Match`/`MatchRound`를 근거로 룸이
   생성되고, 게임서버 파드(`room-pod-<roomId>`)가 뜬다.
2. 그 파드가 60초 동안 `Running` 상태를 유지한다 (죽지 않는다).
3. `room-server`가 그 파드로부터 heartbeat를 계속 받는다(끊기지 않는다).

## 사전 조건 — DB 시드 데이터

`room-server`의 룸 생성 로직은 `matchId`로 `Match` 행을 찾고, 그 매치에 최소 하나의
`MatchRound`(게임모드/맵)가 있어야 게임서버가 씬을 결정할 수 있다. 이 두 행이 없으면
`{"code":20000}` (MATCH_NOT_EXIST) 로 실패하거나, 파드가 뜨더라도 맵을 못 정해 수 초 안에
자멸한다(`System.Exception: 매치에 라운드가 없어 맵을 정할 수 없습니다.`).

**iwinv(dev) DB에는 이미 아래 두 행이 상시 시드로 심어져 있다** (2026-08-10, Task 7):

```sql
-- Match
INSERT INTO "Match" (id, "queueId", "targetRating", "playerList")
VALUES ('test-match-1', 1, 1000, '{}')
ON CONFLICT (id) DO NOTHING;

-- MatchRound (gameModeId=1/mapId=1 = FlapWang/FlapWangMap — matchmaking-server의
-- master_data/tbgamemode.json, tbmap.json에 있는 값)
INSERT INTO "MatchRound" (id, "matchId", "index", "gameModeId", "mapId")
VALUES ('test-match-1-round-0', 'test-match-1', 0, 1, 1)
ON CONFLICT DO NOTHING;
```

다른(새) 환경에 이 E2E를 처음 돌릴 때는 위 두 INSERT를 먼저 실행해야 한다. `Match`/
`MatchRound`는 지우지 않는다 — 아래 "재실행 시 주의" 참고.

## `INTERNAL_API_KEY` 환경변수

`trigger.js`는 room-server의 `/internal/*` 라우트가 요구하는 `x-internal-api-key` 헤더 값을
`process.env.INTERNAL_API_KEY`에서 읽는다 — **스크립트에 값을 박아 넣지 않는다.**
`e2e.sh`가 `kubectl exec deploy/room-server -- node < trigger.js`로 room-server 파드 **안에서**
`trigger.js`를 실행하므로, 그 파드가 이미 `internal-api-secret` Secret으로부터 주입받은
`INTERNAL_API_KEY`를 그대로 물려받는다 — 별도로 값을 넘길 필요가 없다. 이 스크립트를 파드
밖(예: 로컬)에서 돌리려면 같은 값을 환경변수로 넣어 줘야 한다.

## 재실행 시 주의 — `Room.matchId` unique

`Room.matchId`에 유니크 제약이 있어서, 같은 `matchId`로 두 번째 룸을 만들 수 없다.
`e2e.sh`는 실행 시작 시 항상 `Room` 테이블을 비우고 시작하므로(아래), 매번 재실행 가능하다 —
단 **`Match`/`MatchRound`는 지우지 않는다**(재사용 시드).

```bash
kubectl exec -i deploy/postgres-deployment -- psql -U postgres -d postgres -c 'DELETE FROM "Room";'
kubectl delete pods -l app=room-pod --force --grace-period=0
kubectl delete svc -l app=room-service
```

## 사용법 (iwinv)

```bash
scp trigger.js e2e.sh root@115.68.178.46:/root/
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 'bash /root/e2e.sh'
```

기대 결과: `POST /room 응답`에 `"status":2`(RunnerCreated) 이상의 룸 정보가 찍히고, 60초
추적 동안 파드가 계속 `Running`이며, 게임서버 로그 마지막 60줄에 크래시 스택트레이스가
없다.
