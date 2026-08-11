# Infrastructure TODO

언젠가 정리할 인프라 개선 항목 모음. 우선순위 순.

---

## A. README의 `kubectl wait` 명령 수정

**상태: 미해결 (2026-08-11 재확인)** — 여전히 같은 버그가 `README.md`에 남아 있다. 이번에는 두 곳에서
같은 커맨드가 반복된다 — "최초 배포" 섹션(102번째 줄 부근)과 "트러블슈팅" 섹션(199번째 줄 부근).

**현재 (README.md 102, 199라인)**
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

**상태: 해결됨 (2026-08-10, dev 환경 GitOps 전환)**

DB 마이그레이션이 이제 ArgoCD **PreSync hook Job**(`k8s/base/backend/db-migrate/job.yaml`,
`argocd.argoproj.io/hook: PreSync`)으로 자동 실행된다. `wait-for-postgres` initContainer가 postgres
포트가 열릴 때까지 기다린 뒤 마이그레이션 컨테이너가 돈다 — "새 환경 띄울 때마다 수동 단계를 빼먹는"
원래 문제가 해소됐다.

이미지(`re5nardo/lop-db-migrate`)는 `lop-backend` 모노레포의 `packages/database/Dockerfile`에서
빌드되고(`backend-deploy` 워크플로의 `db-migrate` matrix 항목), 그 워크플로가 `k8s/envs/<env>/backend/kustomization.yaml`의
`images:` 블록에 태그를 자동으로 bump한다. 옛 `LOP/db-admin` 레포는 `lop-backend` 통합 시 이 파이프라인 안으로
흡수돼 사라졌다(워크스페이스에 더 이상 존재하지 않음).

**근거 파일:**
- `k8s/base/backend/db-migrate/job.yaml` (PreSync hook 어노테이션)
- `k8s/envs/dev/backend/kustomization.yaml`, `k8s/envs/local/backend/kustomization.yaml` (`images:` 블록의 `re5nardo/lop-db-migrate` 항목)
- `lop-backend/.github/workflows/backend-deploy.yml` (db-migrate matrix: `dockerfile: packages/database/Dockerfile`)

---

## C. Room 인스턴스(Unity `game-server`) Pod 템플릿 위치 확인

**상태: 해결됨 (2026-08-11 확인)**

Pod 템플릿은 `lop-backend` 모노레포의 `apps/room-server/src/services/gameServerPod.ts`
(`buildGameServerPodManifest`)에 **git으로 관리**되고 있음을 확인했다 — 별도 미추적 스크립트가 아니다.

- **이미지**: 하드코딩이 아니라 `process.env.GAME_SERVER_IMAGE`를 읽는다(코드상 fallback만 `:latest`).
  이 값은 이 레포의 `k8s/envs/<env>/backend/game-server-config.env` → `configMapGenerator`가 만든
  `game-server-config` ConfigMap → room-server 컨테이너에 `envFrom`으로 주입되므로, 실제 운영에서는
  항상 CI가 bump하는 커밋 SHA 태그가 쓰인다(예: dev `re5nardo/game-server:c483292`).
- **포트**: 매치별로 동적 할당(`containerPort: port`, `hostPort: port`), UDP.
- **리소스 limit**: Pod spec에 `resources`(CPU/메모리 request/limit)가 지정돼 있지 않다는 점은 이번
  확인 과정에서 새로 발견한 관찰 사항 — 필요해지면 별도로 다룰 것(이 항목의 원래 질문인 "템플릿이
  git에 있는지"와는 별개).

**근거 파일:**
- `lop-backend/apps/room-server/src/services/gameServerPod.ts`
- `k8s/envs/dev/backend/game-server-config.env` (`GAME_SERVER_IMAGE`)
- `k8s/base/backend/room-server/room-server-deployment.yaml` (`envFrom` → `game-server-config`)

---

## D. 이미지 태그 `:latest` 사용 제거

**상태: 해결됨 (2026-08-10, dev 환경 GitOps 전환)**

이 레포가 배포하는 모든 이미지 — 백엔드 4종(`lobby-server`/`matchmaking-server`/`room-server`/`db-migrate`)과
게임서버(`game-server`) — 가 이제 `:latest`가 아니라 **git short SHA**로 고정된다.

- 백엔드: `k8s/envs/<env>/backend/kustomization.yaml`의 `images:` 블록. `backend-deploy` 워크플로의
  `bump-tags` job이 배포마다 `kustomize edit set image`로 값을 자동 갱신한다.
- 게임서버: `k8s/envs/<env>/backend/game-server-config.env`의 `GAME_SERVER_IMAGE`. `gameserver-deploy`
  워크플로가 같은 방식으로 자동 갱신한다.

`k8s/base/backend/*/*.yaml`에 남아 있는 `:latest`는 오버레이 미적용 시의 기본값일 뿐이며, 실제 배포는
항상 두 환경(local/dev)의 `envs/` 오버레이가 씌워진 상태로만 나간다.

이 항목이 원래 참조하던 레포(`LOP/LeagueOfPhysical-LobbyServer`, `LOP/LeagueOfPhysical-RoomServer`)는
`lop-backend` 모노레포 통합 시 archive됐다(워크스페이스에 더 이상 없음). 이 매니페스트가 한때 있었던
옛 경로 `k8s/apps/backend/matchmaking-server/`도 이번 GitOps 작업으로 `k8s/base/backend/matchmaking-server/`로
이동했다.

**근거 파일:**
- `k8s/envs/dev/backend/kustomization.yaml`, `k8s/envs/local/backend/kustomization.yaml` (`images:` 블록)
- `k8s/envs/dev/backend/game-server-config.env`, `k8s/envs/local/backend/game-server-config.env` (`GAME_SERVER_IMAGE`)
- `k8s/base/backend/{lobby-server,matchmaking-server,room-server,db-migrate}/*.yaml` (base 기본값 `:latest`, 오버레이로 항상 덮임)

---

## E. `postgres-secret.yaml` 평문 commit 개선

**상태: 미해결 — 경로만 갱신 (2026-08-11 재확인)**

파일이 `k8s/local-k8s/postgres-secret.yaml`에서 `k8s/base/platform/postgres/postgres-secret.yaml`로
옮겨졌을 뿐, base64만 인코딩된 값이 여전히 git에 그대로 커밋돼 있다(재확인 완료). README의 "최초 배포"
섹션이 이제 `auth-secret`/`internal-api-secret`는 같은 이유로 git에 매니페스트로 두지 않고 클러스터에
수기 생성하도록 안내하지만, `postgres-secret`은 아직 예전 방식(평문 매니페스트 커밋) 그대로다.

**문제**
- base64 인코딩만 된 채로 git에 들어있음 — 보안 아님 (디코드 한 줄)
- 로컬 dev용이라 당장 큰 문제는 아니나, 운영 환경 가면 즉시 폭탄

**옵션**
- 로컬 dev: 이대로 두되 운영에선 절대 사용 금지 주석 추가
- 운영 대비: SealedSecret / External Secrets Operator / Vault 등 도입 (`docs/specs/2026-08-10-dev-env-gitops-design.md` §10도 같은 항목을 "범위 밖 — 운영 단계 과제"로 명시)

**관련 파일:** `k8s/base/platform/postgres/postgres-secret.yaml`

---

## F. Redis 비영속 → 필요 시 PVC 추가

**상태: 미해결 — 경로만 갱신 (2026-08-11 재확인)**

파일이 `k8s/local-k8s/redis-deployment.yaml`에서 `k8s/base/platform/redis/redis-deployment.yaml`로
옮겨졌을 뿐, PVC/볼륨은 여전히 없다(재확인 완료).

**판단 필요**
- 순수 캐시 용도면 의도된 동작, 그대로 OK
- 세션/큐 등 영속이 필요한 데이터가 들어가면 PVC 추가 + `--appendonly yes` 옵션 검토

**관련 파일:** `k8s/base/platform/redis/redis-deployment.yaml`

---

## G. Ingress 신규 라우팅 추가 시 일관성 유지

**상태: 체크리스트로 유지 — 경로만 갱신 (2026-08-11 재확인)**

파일이 `k8s/local-k8s/ingress.yaml`에서 `k8s/base/platform/ingress/ingress.yaml`로 옮겨졌다. 두
환경(local/dev)이 이 파일을 그대로 공유하며(환경별 오버레이 없음), 현재도 `/lobby`, `/matchmaking`,
`/room` 세 경로만 정의돼 있다(재확인 완료) — 신규 서비스 추가 시 여기 업데이트 필수 (TODO 항목이라기보단 체크리스트).

**관련 파일:** `k8s/base/platform/ingress/ingress.yaml`
