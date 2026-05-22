# Infrastructure TODO

언젠가 정리할 인프라 개선 항목 모음. 우선순위 순.

---

## A. README의 `kubectl wait` 명령 수정

**현재 (README 27라인 부근)**
```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=300s
```
이 셀렉터는 admission Job 파드까지 매칭되는데, Job 파드는 `Completed` 상태로 끝나서 절대 `Ready` 안 됨 → 항상 타임아웃 후 실패로 보임 (실제 컨트롤러는 정상 기동돼 있음).

**수정안**
```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=300s
```

**관련 파일:** `README.md`

---

## B. Prisma 마이그레이션 자동화

**현재 상태**
- DB 스키마/시드 적용이 `LOP/db-admin` 레포에서 수동 실행 (`prisma db push` + `npm run seed`)
- 새 환경 띄울 때마다 별도 단계로 신경 써야 함, 빼먹기 쉬움

**옵션**
1. k8s `Job` 리소스로 만들어 한 번 실행 (db-admin 이미지화 필요)
2. lobby/matchmaking/room deployment에 `initContainer` 추가해 부팅 전 보장
3. 적용 가이드를 infrastructure README에 명시적으로 포함

**관련 파일:** `LOP/db-admin/*`, 각 서버 deployment yaml

---

## C. Room 인스턴스(Unity `game-server`) Pod 템플릿 위치 확인

**현재 상태**
- `room-server` Pod은 RBAC로 default ns에 pod/service create/delete 권한 갖춤
- 즉 매치 생성 시 Unity 게임 서버 Pod을 동적으로 띄우는 구조
- 그런데 어떤 매니페스트(이미지/포트/리소스 limit)를 만드는지는 코드 안에 있을 것 — 매니페스트 템플릿 파일이 별도 존재한다면 git에 같이 관리되는지 점검 필요

**관련 이미지:** `re5nardo/game-server:latest` (Unity 헤드리스, 포트 7777)
**관련 파일:** `LOP/LeagueOfPhysical-RoomServer/RoomServer/src/` 안에서 Pod spec 생성 로직 찾기

---

## D. 이미지 태그 `:latest` 사용 제거

**문제**
- 모든 deployment가 `:latest` 참조 → 재현성 떨어짐, 의도치 않게 이미지 바뀔 수 있음
- 롤백도 어려움 (이전 이미지 SHA 추적 안 됨)

**수정안**
- 의미있는 태그 (`v0.1.0`, git short SHA 등) + `imagePullPolicy: IfNotPresent`
- CI/CD 도입 시 자동 태깅 워크플로우 같이 마련

**관련 파일:**
- `LOP/LeagueOfPhysical-LobbyServer/LobbyServer/k8s/local-k8s/lobby-server-deployment.yaml`
- `LOP/LeagueOfPhysical-MatchmakingServer/MatchmakingServer/k8s/local-k8s/matchmaking-server-deployment.yaml`
- `LOP/LeagueOfPhysical-RoomServer/RoomServer/k8s/local-k8s/room-server-deployment.yaml`

---

## E. `postgres-secret.yaml` 평문 commit 개선

**문제**
- base64 인코딩만 된 채로 git에 들어있음 — 보안 아님 (디코드 한 줄)
- 로컬 dev용이라 당장 큰 문제는 아니나, 운영 환경 가면 즉시 폭탄

**옵션**
- 로컬 dev: 이대로 두되 운영에선 절대 사용 금지 주석 추가
- 운영 대비: SealedSecret / External Secrets Operator / Vault 등 도입

**관련 파일:** `k8s/local-k8s/postgres-secret.yaml`

---

## F. Redis 비영속 → 필요 시 PVC 추가

**현재 상태**
- `redis-deployment.yaml` 에 PVC 없음 → Pod 재시작 시 데이터 날아감

**판단 필요**
- 순수 캐시 용도면 의도된 동작, 그대로 OK
- 세션/큐 등 영속이 필요한 데이터가 들어가면 PVC 추가 + `--appendonly yes` 옵션 검토

**관련 파일:** `k8s/local-k8s/redis-deployment.yaml`

---

## G. Ingress 신규 라우팅 추가 시 일관성 유지

**현재 상태**
- `ingress.yaml` 에 `/lobby`, `/matchmaking`, `/room` 만 정의
- 신규 서비스 추가 시 여기 업데이트 필수 (TODO 항목이라기보단 체크리스트)

**관련 파일:** `k8s/local-k8s/ingress.yaml`
