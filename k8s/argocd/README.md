# ArgoCD app-of-apps

## 구조

```
k8s/argocd/
├── root-app.yaml        # app-of-apps 루트 (argocd 네임스페이스가 관리)
├── apps/
│   ├── platform.yaml     # sync-wave "0" — DB/redis/ingress/RBAC (k8s/platform)
│   └── backend.yaml      # sync-wave "1" — lobby/matchmaking/room + db-migrate (k8s/apps/backend)
└── install/              # ArgoCD 자체 설치 절차 (부트스트랩, ArgoCD 밖에서 관리)
```

`root` Application이 `k8s/argocd/apps` 디렉토리를 지켜보며 그 안의 `platform`/`backend` Application을 자동으로 생성·관리한다 (app-of-apps 패턴). 세 Application 모두 `syncPolicy.automated: {prune: true, selfHeal: true}` — 레포에 반영된 상태가 곧 클러스터 상태가 된다.

## sync-wave 순서

1. **wave 0 — platform**: postgres/mongodb/redis/ingress-nginx-경유 리소스/RBAC가 먼저 배포된다.
2. **wave 1 — backend**: platform이 Synced 된 뒤 적용. `db-migrate` Job은 `PreSync` hook으로 등록되어 있어 lobby/matchmaking/room 서버 Deployment보다 먼저 실행되고, 그 안의 `wait-for-postgres` initContainer가 postgres 포트가 열릴 때까지 재차 대기한다 (sync-wave와 이중 안전장치).

## 접속법

- ArgoCD UI/CLI: `kubectl port-forward svc/argocd-server -n argocd 8080:443` 후 `https://localhost:8080` (초기 admin 비밀번호는 `k8s/argocd/install/README.md` 참고).
- 배포된 서비스: ingress-nginx NodePort 31000 경유, 예) `http://localhost:31000/lobby/`.
- Application 상태 확인: `kubectl get applications -n argocd`.

## 배포 = 커밋 + push → 자동 sync

이 레포(`k8s/platform`, `k8s/apps/backend`, `k8s/argocd/apps`)에 변경을 커밋하고 `main`에 push하면, ArgoCD가 자동으로 감지해 `automated` 정책에 따라 sync한다. 수동으로 `kubectl apply`할 필요가 없다 — 클러스터에 직접 넣은 변경은 selfHeal에 의해 되돌아간다(GitOps 원칙: Git이 source of truth).

## 롤백 = 커밋 revert

문제가 생기면 해당 변경 커밋을 `git revert`하고 push한다. ArgoCD가 이전 상태로 자동 sync한다. 강제로 되돌려야 하면 ArgoCD UI/CLI에서 History에서 이전 revision으로 롤백할 수도 있다.

## 부트스트랩 (ArgoCD 밖에서 관리되는 것)

- **ArgoCD 자체 설치**: `k8s/argocd/install/`에 절차 문서화. app-of-apps가 관리하는 대상이 아니다 (ArgoCD가 자기 자신을 관리하지 않음).
- **ingress-nginx 컨트롤러**: 클러스터 부트스트랩 단계에서 별도로 설치됨 (로컬 Docker Desktop 환경 기준). `k8s/platform/ingress`는 컨트롤러가 아니라 Ingress/서비스 라우팅 리소스만 관리한다.

## Phase 2 완료 (백엔드 CI)

- ✅ **이미지 sha 태깅** — backend-deploy 워크플로가 멀티아치 이미지를 `re5nardo/<app>:<git-sha>`로 빌드·푸시하고 `kustomize edit set image`로 매니페스트 태그를 bump. 더 이상 `:latest`에 의존하지 않음.
- ✅ **lobby/matchmaking/room 3종 모노레포 이미지 재빌드·검증** — 첫 CI 실행(`all`)이 3종을 모노레포 코드로 재빌드해 ArgoCD 배포·기동 확인. 구 pre-monorepo 이미지 드리프트 트랩 해소.
- ✅ **미사용 ts-node 제거** (lop-backend `packages/database`).

## Phase 3 완료 (Unity 게임서버 CI)

게임서버는 room-server가 매치마다 동적으로 pod로 띄우는 Unity 데디케이티드 서버다. 배포 흐름:

1. **LeagueOfPhysical-Server** 레포 → GitHub Actions **gameserver-deploy** 버튼 (셀프호스트 러너 = 맥, Unity 라이선스)
2. 셀프호스트 러너가 의존 UPM 레포(GameFramework/Shared/MasterData-Server)를 형제 위치에 클론 → Unity batchmode Linux 서버 빌드 → 도커 이미지 `re5nardo/game-server:<git-sha>`(amd64) 빌드·푸시
3. infra의 **`game-server-config` ConfigMap**(`GAME_SERVER_IMAGE`)을 그 sha로 bump·commit·push
4. ArgoCD가 ConfigMap 갱신 → **room-server**가 `GAME_SERVER_IMAGE` env로 매치 pod 이미지를 결정 (하드코딩 `:latest` 제거됨, fallback 유지). room-server는 재시작 시 새 값 반영.

### 러너
- 맥에 launchd 서비스로 상주(`~/actions-runner-lop`, `lop-mac-runner`). Unity 라이선스·docker는 맥 로컬 사용.
- **주의(launchd keychain)**: launchd 서비스는 맥 keychain에 접근 못 해 docker/git ambient 인증이 실패한다. 그래서 워크플로는 시크릿(`DOCKERHUB_*`, `INFRA_REPO_TOKEN`) + `DOCKER_CONFIG`에 inline auth를 직접 작성해 keychain을 우회한다.

### 후속 항목
- **IL2CPP 미적용(현재 Mono)**: Linux IL2CPP 크로스컴파일 sysroot 툴체인이 맥에 없어(`Unable to find Linux Sysroot`) Mono 백엔드로 빌드 중. sysroot 설치(에디터에서 Linux IL2CPP 1회 빌드 시 UPM sysroot 패키지 자동 추가) 후 `BuildScript.cs`를 IL2CPP로 되돌리면 됨.
- **게임서버 arch = amd64**: Unity 단일 아키 빌드. 로컬 arm64 클러스터에서 실제 pod 기동은 에뮬레이션/arm64 빌드 필요(이번 검증 범위 밖 — 배선까지 확인).
- room.service.ts `getPublicIP` 하드코딩 `localhost` — 클라우드 노출 시 과제.

## 남은 hardening 이월 항목

- **db-migrate 이미지 슬림화** — 현재 2.27GB(단일 스테이지 + tsc용 full devDep 설치). 앱 Dockerfile처럼 builder/runtime 멀티스테이지로 분리 가능.
- **앱 deployment에 resource requests/limits·health probe·replica>1 부재** (기존 매니페스트 그대로 이관됨) — 운영 대비 hardening 필요.

> 참고: 초기 배포 시 seed 단계가 ts-node ESM directory-import 버그(`ERR_UNSUPPORTED_DIR_IMPORT`)로 실패했으나, seed를 CommonJS로 컴파일해 `node dist/seed.js`로 실행하도록 수정 완료(lop-backend `5b42d88`/`e421be9`). 현재 정상 동작한다.
