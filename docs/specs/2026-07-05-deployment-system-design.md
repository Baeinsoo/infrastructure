# LOP 배포 시스템 설계

- 날짜: 2026-07-05
- 상태: 확정 (구현 전)
- 범위: 백엔드 서버 3종, Unity 게임서버 이미지, 인프라(DB·Redis·Ingress), Unity 클라이언트 앱/콘텐츠

## 1. 목표와 결정 사항

| 항목 | 결정 |
|---|---|
| 타깃 환경 | 로컬 k8s 클러스터 (클라우드 이전은 이후 단계) |
| CD / 배포 대시보드 | ArgoCD (GitOps, app-of-apps) |
| CI / 트리거 | GitHub Actions `workflow_dispatch` 버튼 + 맥 셀프호스트 러너 |
| Unity 빌드 | batchmode로 완전 자동화 (에디터 수동 빌드 제거) |
| 백엔드 레포 구조 | lobby/matchmaking/room + db-admin → **lop-backend 모노레포** 통합 (Phase 0) |
| 매니페스트 위치 | infrastructure 레포로 집결 (배포 상태의 단일 진실, Kustomize) |
| 이미지 태그 | `:latest` 폐지 → `:<git-sha>`. 롤백 = infrastructure 커밋 revert |
| 어드레서블 | 클라이언트 앱과 **독립된 파이프라인**으로 배포 (Content Update 워크플로 기반) |

역할 분담: 빌드(CI) 상태·로그·이력은 GitHub Actions 콘솔, 배포(CD) 상태·롤백·diff는 ArgoCD 대시보드.

## 2. 전체 아키텍처

```
[개발자] ─ GitHub "Run workflow" 버튼 (추후 push 자동 트리거 확장 가능)
   ▼
[GitHub Actions — 맥 셀프호스트 러너]
   ├─ lop-backend:   변경 앱 빌드·테스트 → 이미지 push (re5nardo/*:<git-sha>)
   ├─ 게임서버:      Unity batchmode Linux 빌드 → 도커화 → push
   ├─ 클라이언트 앱: Unity batchmode APK → S3
   └─ 콘텐츠:        Addressables 빌드 → S3   (앱과 독립)
   │
   │ (k8s 배포 대상만) infrastructure 레포의 이미지 태그 bump + commit
   ▼
[infrastructure 레포] ← GitOps 단일 진실
   ▼  ArgoCD auto-sync
[로컬 k8s] ─ ArgoCD / lobby·matchmaking·room / postgres·mongo·redis·ingress
             / game-server 파드 (room-server가 동적 생성, 태그는 ConfigMap에서)
```

## 3. Phase 0 — lop-backend 모노레포

```
lop-backend/                          (신규 레포)
├── pnpm-workspace.yaml
├── package.json / turbo.json / tsconfig.base.json
├── apps/
│   ├── lobby-server/                 # 각자 Dockerfile 유지, 독립 배포 단위
│   ├── matchmaking-server/
│   └── room-server/                  # server_binary/ 커밋본은 제거
├── packages/
│   ├── database/                     # 구 db-admin 승계 — 스키마 단일 소유자
│   │   ├── prisma/schema.prisma + migrations/
│   │   ├── src/seed.ts + tables/*.csv
│   │   ├── Dockerfile               # 마이그레이션 Job용 경량 이미지
│   │   └── package.json             # @lop/database — Prisma 클라이언트 export
│   └── shared/                       # @lop/shared — 서버 간 API 타입, 공통 유틸
└── .github/workflows/
```

핵심 결정:

- **pnpm workspaces + Turborepo** (npm → pnpm 전환). Turborepo가 "변경된 것만 빌드·테스트" 담당.
- **스키마 단일화**: 각 서버의 `prisma/` 사본 삭제 → `@lop/database` import. 현재 db-admin과 각 서버의 스키마가 이미 갈라져 있는 문제(실제 DB는 db-admin이 만들고, 서버들은 자기 사본으로 클라이언트 생성)를 구조적으로 해결.
- **도커화**: 앱별 Dockerfile을 workspace 루트 컨텍스트 기준으로 재작성, `pnpm --filter <app> deploy` 패턴으로 해당 앱+의존 패키지만 이미지에 포함.
- 기존 4개 레포(LobbyServer/MatchmakingServer/RoomServer/db-admin)는 GitHub에서 **archive** (히스토리 참조용). 새 레포는 fresh start.
- LobbyServer의 레거시 `appspec.yml`(CodeDeploy)은 승계하지 않음.
- `.env.development.local` / `.env.development.local-k8s` 관례는 유지.

## 4. 파이프라인 (GitHub Actions)

공통: 전부 `workflow_dispatch`, 맥 셀프호스트 러너. 러너 1대라 워크플로 중첩 시 자동 큐잉. Unity 라이선스는 맥에 활성화된 것을 batchmode가 그대로 사용.

### ① lop-backend — 백엔드 배포

1. 입력: 대상(lobby / matchmaking / room / database / all)
2. `pnpm install` → `turbo run build test`
3. 대상별 `docker buildx build`(amd64+arm64) → push `re5nardo/<app>-server:<git-sha>`
4. `database` 변경 시 `re5nardo/lop-db-migrate:<sha>`도 빌드
5. infrastructure checkout → `kustomize edit set image` → commit/push

### ② LeagueOfPhysical-Server — Unity 게임서버

1. checkout (+ Art 서브모듈)
2. `Unity -batchmode -quit -executeMethod BuildScript.BuildLinuxServer` → Linux Dedicated Server(IL2CPP) 빌드
3. `docker buildx build`(amd64) → push `re5nardo/game-server:<git-sha>`
4. infrastructure의 game-server ConfigMap 태그 bump → commit/push

선행 작업: (a) `BuildScript.cs` 에디터 빌드 스크립트 작성, (b) 맥 Unity에 Linux Dedicated Server Build Support(IL2CPP) 모듈 설치, (c) **room-server 수정** — `room.service.ts`의 하드코딩된 `re5nardo/game-server:latest`를 ConfigMap 주입 env로 변경. git 커밋된 `Build/`(654MB)와 room-server `server_binary/` 사본 제거.

### ③a LeagueOfPhysical-Client — 앱(APK) 배포

1. Unity batchmode `BuildAndroid` → `lop.apk`
2. 이 시점의 `addressables_content_state.bin`을 `s3://lop-client/builds/<sha>/`에 함께 보존하고 `latest` 포인터 갱신 (콘텐츠 파이프라인의 기준점)
3. S3 업로드: `s3://lop-client/builds/<sha>/` + `latest` 갱신 (단일 파일 덮어쓰기 폐지)

### ③b 콘텐츠(Addressables) 배포 — 앱과 완전 독립

1. S3에서 최신 앱 릴리스의 `addressables_content_state.bin` 다운로드
2. Unity batchmode Addressables 빌드 — 기본 모드 **"Update a Previous Build"** (해당 content_state 기준 → 설치된 앱과 카탈로그 호환 보장)
3. S3 업로드: `s3://lop-assets/dev/<platform>/` (기존 sync 방식)

운영 모델: 앱은 가끔(코드 변경 시), 콘텐츠는 수시로 — 버튼이 따로 있고 서로를 기다리지 않는다.

## 5. infrastructure 레포 개편 + ArgoCD

```
infrastructure/
├── k8s/
│   ├── platform/                     # postgres/ mongodb/ redis/ ingress/ rbac/
│   ├── apps/
│   │   ├── backend/                  # lobby·matchmaking·room 매니페스트 집결
│   │   │   ├── db-migrate-job.yaml   # ArgoCD PreSync 훅 (migrate deploy + seed)
│   │   │   └── kustomization.yaml    # 이미지 태그 관리 지점 (CI가 bump)
│   │   └── game-server/configmap.yaml  # game-server 이미지 태그
│   └── argocd/
│       ├── root-app.yaml             # app-of-apps 루트
│       └── apps/                     # platform / backend / game-server-config
├── table/                            # 기존 Luban 파이프라인 그대로
└── README.md                         # 새 구조 반영 재작성
```

- ArgoCD는 `argocd` 네임스페이스에 공식 매니페스트로 설치. 접속은 `kubectl port-forward`(필요 시 ingress `argocd.localhost` 추가).
- **Application 구성**: `platform` / `backend` / `game-server-config` 3개.
  - `backend`는 서버 3종 + PreSync 마이그레이션 Job을 한 앱으로 묶음 — PreSync 훅으로 "마이그레이션 → 서버 배포" 순서가 보장됨. 대시보드에서는 앱 내 리소스 트리로 deployment별 상태 확인 가능.
- **sync 정책**: auto-sync + self-heal. 수동 게이트는 GitHub 버튼 쪽에 이미 있으므로 ArgoCD에는 두지 않음.
- 각 서버 레포에 흩어져 있던 `k8s/local-k8s/` 매니페스트는 이 레포로 이관 후 원본 삭제.

## 6. 시크릿

- k8s 시크릿(postgres): 로컬 전용 명시 주석 추가 후 git 유지. 클라우드 이전 시 SealedSecrets 도입 (TODO 명문화).
- GitHub Actions Secrets (신규): Docker Hub 토큰, infrastructure push용 PAT, S3용 AWS 키.

## 7. 검증 계획 (구축 완료의 정의)

1. lobby 코드 변경 → 버튼 → ArgoCD sync → 파드가 새 `<sha>` 이미지로 기동
2. infrastructure 커밋 revert → 이전 버전으로 롤백 확인
3. 스키마 필드 추가 → 버튼 → PreSync Job이 마이그레이션 실행 후 서버 배포
4. 게임서버 버튼 → 새 이미지 push → 신규 매치 파드가 새 태그로 기동
5. 콘텐츠 버튼만 실행 → 앱 재설치 없이 어드레서블 갱신 확인

## 8. 구축 순서

| Phase | 내용 | 독립 검증 |
|---|---|---|
| 0 | lop-backend 모노레포 통합 (+db-admin 흡수) | 로컬에서 3서버 빌드·기동 |
| 1 | infrastructure 개편 + ArgoCD 설치·앱 등록 | 수동 태그 bump로 sync 확인 |
| 2 | 백엔드 워크플로 + 셀프호스트 러너 | 검증 1·2·3 |
| 3 | 게임서버 파이프라인 (BuildScript, room-server 수정) | 검증 4 |
| 4 | 클라이언트 앱/콘텐츠 파이프라인 분리 구축 | 검증 5 |

## 9. 의도적으로 범위에서 제외한 것

- 클라우드 이전 (EKS/GKE, 관리형 DB, 시크릿 매니저) — Kustomize overlay(`local-k8s`)와 워크플로 구조를 그대로 확장 가능하게 설계
- 모니터링/알림 (Prometheus, Grafana, Slack)
- push 자동 트리거 — 워크플로에 `push:` 트리거 한 줄 추가로 전환 가능
- staging/prod 환경 분리, HA(replicas>1)
- game-server public IP 하드코딩(`localhost`) 해결 — 클라우드 이전 시 과제
