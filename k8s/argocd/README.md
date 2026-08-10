# ArgoCD app-of-apps

## 환경마다 별도 ArgoCD

이 레포는 **클러스터마다 자체 ArgoCD**를 둔다(허브-스포크 구조가 아니다) — 각 클러스터의 ArgoCD가 같은
public 레포(`https://github.com/Baeinsoo/infrastructure`)의 **자기 환경 경로만** 본다. 그래서
`k8s/argocd/`는 환경별로 완전히 분리된 두 트리(`envs/local`, `envs/dev`)를 갖는다.

`root`/`platform`/`backend`라는 **Application 이름은 두 환경에서 동일**하게 유지한다. 서로 다른
클러스터에 있으므로 이름이 겹쳐도 충돌하지 않는다. **이름은 여전히 절대 바꾸지 않는다** — 단 그 이유는
"바꾸면 캐스케이드 삭제된다"가 아니라 그 반대에 가깝다: 캐스케이드 여부는 kubectl의 `--cascade` 플래그가
아니라 Application에 `resources-finalizer.argocd.argoproj.io` finalizer가 붙어 있는지로 결정되고, 지금
세 Application 모두 그 finalizer가 없다(`k8s/argocd/install/README.md`의 "GitOps 자체를 되돌리기" 절
참고). 이 상태에서 이름을 바꾸면(=구 이름 Application이 삭제 대상이 됨) 워크로드는 삭제되지 않고 ArgoCD
추적에서만 떨어져 **고아 상태**가 되며, 새 이름의 Application이 같은 리소스를 다시 sync하려 할 때
소유권 충돌을 겪을 수 있다. 반대로 ArgoCD UI/CLI(`argocd app delete`)로 지우면 삭제 시점에 finalizer를
붙였다 지우는 경로라 그때는 실제로 캐스케이드 삭제된다. 두 경로 모두 원치 않는 결과이므로 이름은
바꾸지 않는다.

## 구조

```
k8s/argocd/
├── envs/
│   ├── local/
│   │   ├── root-app.yaml   # app-of-apps 루트 (argocd 네임스페이스가 관리) → k8s/argocd/envs/local/apps
│   │   └── apps/
│   │       ├── platform.yaml # sync-wave "0" — DB/redis/ingress/RBAC (k8s/base/platform)
│   │       └── backend.yaml  # sync-wave "1" — lobby/matchmaking/room + db-migrate (k8s/envs/local/backend)
│   └── dev/
│       ├── root-app.yaml   # → k8s/argocd/envs/dev/apps
│       └── apps/
│           ├── platform.yaml # sync-wave "0" — k8s/base/platform (local과 완전히 동일한 파일)
│           └── backend.yaml  # sync-wave "1" — k8s/envs/dev/backend
└── install/              # ArgoCD 자체 설치 절차 (부트스트랩, ArgoCD 밖에서 관리)
```

각 환경의 `root` Application이 자기 `k8s/argocd/envs/<env>/apps` 디렉토리를 지켜보며 그 안의
`platform`/`backend` Application을 자동으로 생성·관리한다 (app-of-apps 패턴). 모든 Application이
`syncPolicy.automated: {prune: true, selfHeal: true}` — 레포에 반영된 상태가 곧 (그 환경의) 클러스터
상태가 된다.

## 두 환경의 path 대응표

| Application | local | dev |
|---|---|---|
| `root`(source path) | `k8s/argocd/envs/local/apps` | `k8s/argocd/envs/dev/apps` |
| `platform`(source path) | `k8s/base/platform` | `k8s/base/platform` (동일) |
| `backend`(source path) | `k8s/envs/local/backend` | `k8s/envs/dev/backend` |
| destination cluster | `https://kubernetes.default.svc` (kind, 컨텍스트 `kind-lop`) | `https://kubernetes.default.svc` (iwinv k3s, `115.68.178.46`) |

`destination.server`가 두 환경 모두 `https://kubernetes.default.svc`인 이유는 **각 클러스터 안에서
동작하는 자기 자신의 ArgoCD**를 가리키기 때문이다 — 원격 클러스터를 가리키는 게 아니라 "이 ArgoCD가 떠
있는 바로 이 클러스터"라는 뜻이다.

## sync-wave 순서

1. **wave 0 — platform**: postgres/redis/ingress-nginx-경유 리소스/RBAC가 먼저 배포된다(mongodb는
   이 프로젝트가 GitOps로 넘어오기 전에 매니페스트에서 제거됐다 — 지금 `k8s/base/platform`에 없다).
2. **wave 1 — backend**: platform이 Synced 된 뒤 적용. `db-migrate` Job은 `PreSync` hook으로 등록되어 있어 lobby/matchmaking/room 서버 Deployment보다 먼저 실행되고, 그 안의 `wait-for-postgres` initContainer가 postgres 포트가 열릴 때까지 재차 대기한다 (sync-wave와 이중 안전장치).

## 접속법

- ArgoCD UI/CLI: `kubectl port-forward svc/argocd-server -n argocd 8080:443` 후 `https://localhost:8080` (초기 admin 비밀번호는 `k8s/argocd/install/README.md` 참고).
- 배포된 서비스: 환경마다 접속 형태가 다르다 — local은 kind의 `extraPortMappings`로 31000/32000이 내
  PC의 80/443으로 옮겨져 `http://localhost/lobby/`(포트 없이), dev(iwinv)는 NodePort를 그대로
  `http://115.68.178.46:31000/lobby/`. `http://localhost:31000/...`은 Docker Desktop 시절 잔재로 kind
  전환 이후 어느 환경에서도 접속되지 않는다(상세는 최상위 `README.md`의 "외부 접근" 절, dev 형태의
  근거는 `k8s/argocd/install/README.md`의 "Access" 절 참고).
- Application 상태 확인: `kubectl get applications -n argocd`.

## 배포 = 커밋 + push → 자동 sync

이 레포(`k8s/base/platform`, `k8s/envs/<env>/backend`, `k8s/argocd/envs/<env>/apps`)에 변경을 커밋하고 `main`에 push하면, 그 환경을 보는 ArgoCD가 자동으로 감지해 `automated` 정책에 따라 sync한다. 수동으로 `kubectl apply`할 필요가 없다 — 클러스터에 직접 넣은 변경은 selfHeal에 의해 되돌아간다(GitOps 원칙: Git이 source of truth). `platform`은 환경 구분 없이 한 경로(`k8s/base/platform`)를 커밋하면 **두 환경 모두**에 반영된다.

## 롤백 = 커밋 revert

문제가 생기면 해당 변경 커밋을 `git revert`하고 push한다. ArgoCD가 이전 상태로 자동 sync한다. 강제로 되돌려야 하면 ArgoCD UI/CLI에서 History에서 이전 revision으로 롤백할 수도 있다.

## 부트스트랩 (ArgoCD 밖에서 관리되는 것)

- **ArgoCD 자체 설치**: `k8s/argocd/install/`에 절차 문서화. app-of-apps가 관리하는 대상이 아니다 (ArgoCD가 자기 자신을 관리하지 않음).
- **ingress-nginx 컨트롤러**: 클러스터 부트스트랩 단계에서 별도로 설치됨 (local은 kind, `k8s/local-k8s/ingress-nginx-deploy.yaml`). `k8s/base/platform/ingress`는 컨트롤러가 아니라 Ingress/서비스 라우팅 리소스만 관리한다.

## Phase 2 완료 (백엔드 CI)

- ✅ **이미지 sha 태깅** — backend-deploy 워크플로가 멀티아치 이미지를 `re5nardo/<app>:<git-sha>`로 빌드·푸시하고 `kustomize edit set image`로 매니페스트 태그를 bump. 더 이상 `:latest`에 의존하지 않음.
- ✅ **lobby/matchmaking/room 3종 모노레포 이미지 재빌드·검증** — 첫 CI 실행(`all`)이 3종을 모노레포 코드로 재빌드해 ArgoCD 배포·기동 확인. 구 pre-monorepo 이미지 드리프트 트랩 해소.
- ✅ **미사용 ts-node 제거** (lop-backend `packages/database`).

## Phase 3 완료 (Unity 게임서버 CI)

게임서버는 room-server가 매치마다 동적으로 pod로 띄우는 Unity 데디케이티드 서버다. 배포 흐름:

1. **LeagueOfPhysical-Server** 레포 → GitHub Actions **gameserver-deploy** 버튼 (셀프호스트 러너 = 맥, Unity 라이선스)
2. 셀프호스트 러너가 의존 UPM 레포(GameFramework/Shared/MasterData-Server)를 형제 위치에 클론 → Unity batchmode Linux 서버 빌드(IL2CPP, amd64+arm64 각각) → `docker buildx imagetools`로 `re5nardo/game-server:<git-sha>` **멀티아치** 이미지 빌드·푸시
3. infra의 **`k8s/envs/<env>/backend/game-server-config.env`**(`GAME_SERVER_IMAGE`)을 그 sha로 bump·commit·push
4. 그 환경의 ArgoCD가 sync → `configMapGenerator`가 새 해시의 `game-server-config-<해시>` ConfigMap을 만들고 room-server Deployment가 자동 롤링 재시작(수기 `rollout restart` 불필요) → **room-server**가 `GAME_SERVER_IMAGE` env로 매치 pod 이미지를 결정 (하드코딩 `:latest` 제거됨, fallback 유지).

### 러너
- 맥에 launchd 서비스로 상주(`~/actions-runner-lop`, `lop-mac-runner`). Unity 라이선스·docker는 맥 로컬 사용.
- **주의(launchd keychain)**: launchd 서비스는 맥 keychain에 접근 못 해 docker/git ambient 인증이 실패한다. 그래서 워크플로는 시크릿(`DOCKERHUB_*`, `INFRA_REPO_TOKEN`) + `DOCKER_CONFIG`에 inline auth를 직접 작성해 keychain을 우회한다.

### 후속 항목 (하드닝으로 해소됨 — 2026-07-12)

위 세 항목은 이 절이 처음 쓰였을 때(Phase 3, Mono/amd64 단일 아치 시절)의 이월 목록이었으나,
2026-07-12 하드닝 슬라이스로 모두 해소됐다(최상위 `README.md`의 "게임서버 배포" 절 참고):

- ~~IL2CPP 미적용(Mono)~~ → **IL2CPP 적용됨**(`BuildScript.cs`가 `ScriptingImplementation.IL2CPP` 설정, arm64 Linux는 애초에 IL2CPP 전용이라 Mono 선택지가 없음).
- ~~게임서버 arch = amd64 단일~~ → **멀티아치(amd64+arm64)**. 로컬 arm64 클러스터에서 네이티브 pod 기동까지 검증됨.
- ~~room.service.ts `getPublicIP` 하드코딩 `localhost`~~ → **`GAME_SERVER_PUBLIC_IP` env로 주입**(fallback만 `localhost`). 값은 환경별 `k8s/envs/<env>/backend/game-server-config.env`에 고정(local `127.0.0.1`, dev iwinv 공인 IP).

## 남은 hardening 이월 항목

- **db-migrate 이미지 슬림화** — 현재 2.27GB(단일 스테이지 + tsc용 full devDep 설치). 앱 Dockerfile처럼 builder/runtime 멀티스테이지로 분리 가능.
- **앱 deployment에 resource requests/limits·health probe·replica>1 부재** (기존 매니페스트 그대로 이관됨) — 운영 대비 hardening 필요.

> 참고: 초기 배포 시 seed 단계가 ts-node ESM directory-import 버그(`ERR_UNSUPPORTED_DIR_IMPORT`)로 실패했으나, seed를 CommonJS로 컴파일해 `node dist/seed.js`로 실행하도록 수정 완료(lop-backend `5b42d88`/`e421be9`). 현재 정상 동작한다.
