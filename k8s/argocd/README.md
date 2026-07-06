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

## 남은 hardening 이월 항목

- **db-migrate 이미지 슬림화** — 현재 2.27GB(단일 스테이지 + tsc용 full devDep 설치). 앱 Dockerfile처럼 builder/runtime 멀티스테이지로 분리 가능.
- **앱 deployment에 resource requests/limits·health probe·replica>1 부재** (기존 매니페스트 그대로 이관됨) — 운영 대비 hardening 필요.

> 참고: 초기 배포 시 seed 단계가 ts-node ESM directory-import 버그(`ERR_UNSUPPORTED_DIR_IMPORT`)로 실패했으나, seed를 CommonJS로 컴파일해 `node dist/seed.js`로 실행하도록 수정 완료(lop-backend `5b42d88`/`e421be9`). 현재 정상 동작한다.
