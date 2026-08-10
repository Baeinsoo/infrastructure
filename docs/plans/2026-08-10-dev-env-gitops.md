# dev 환경(iwinv) GitOps 전환 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** infrastructure 매니페스트를 `base/` + `envs/{local,dev}/`로 가르고, iwinv k3s에 자체 ArgoCD를 설치해 지금까지 수동(rsync + `kubectl apply -k`)이던 dev 배포를 GitOps로 전환한다.

**Architecture:** Kustomize base/overlay로 환경 차이(`GAME_SERVER_PUBLIC_IP`, 이미지 태그)를 환경 폴더 한 곳에 모은다. 클러스터마다 자체 ArgoCD가 같은 public 레포의 자기 환경 경로를 본다(허브-스포크 아님 — 맥이 꺼져도 iwinv가 동기화되어야 함). 배포 CI 2종에 `environment` 입력을 추가해 어느 환경 태그를 bump할지 고른다.

**Tech Stack:** Kustomize (kubectl v1.32 내장 v5.5.0), ArgoCD v2.13.2, k3s(iwinv) / kind(local), GitHub Actions

**설계 문서:** `docs/specs/2026-08-10-dev-env-gitops-design.md`

## Global Constraints

- **작업 레포가 3개다.** Task마다 어느 레포인지 명시돼 있다. 각 레포에서 **main에 직접 커밋하지 않는다** — 피처 브랜치에서 작업 후 `--no-ff` 머지.
  - infrastructure: 워크트리 `/Users/insoobae/workspace/LOP/.worktrees/infra-dev-env-gitops`, 브랜치 `feature/dev-env-gitops` (이미 생성됨)
  - lop-backend: `/Users/insoobae/workspace/LOP/lop-backend`
  - LeagueOfPhysical-Server: `/Users/insoobae/workspace/LOP/LeagueOfPhysical-Server`
- **ArgoCD Application 이름은 `root` / `platform` / `backend`로 고정.** 이름을 바꾸면 옛 Application이 삭제되면서 딸린 워크로드까지 캐스케이드 삭제된다.
- **kustomize 실행은 `kubectl kustomize <dir>`를 쓴다.** 이 맥에 standalone `kustomize` 바이너리가 없다(CI에는 v5.4.3이 설치된다).
- 현재 이미지 태그(이식 시 그대로 복사): 백엔드 4종 모두 `9937c81`, 게임서버 `re5nardo/game-server:6b4bb35`
- 환경별 고정값: local `GAME_SERVER_PUBLIC_IP=127.0.0.1` / dev `GAME_SERVER_PUBLIC_IP=115.68.178.46`
- iwinv 접속: `ssh -i ~/.ssh/iwinv_lop root@115.68.178.46`
- **Task 6·7은 라이브 서버를 건드린다.** 각 Task 시작 전에 사용자 확인을 받는다.

---

## Task 1: 매니페스트를 base/envs로 분리 + configMapGenerator 도입

**레포:** infrastructure (워크트리 `infra-dev-env-gitops`)

**Files:**
- Move: `k8s/platform/` → `k8s/base/platform/`
- Move: `k8s/apps/backend/` → `k8s/base/backend/`
- Modify: `k8s/base/backend/kustomization.yaml` (game-server-config 제거)
- Modify: `k8s/base/backend/{lobby-server,matchmaking-server,room-server,db-migrate}/kustomization.yaml` (`images:` 블록 제거)
- Delete: `k8s/base/backend/game-server-config/`
- Create: `k8s/envs/local/backend/{kustomization.yaml,game-server-config.env}`
- Create: `k8s/envs/dev/backend/{kustomization.yaml,game-server-config.env}`

**Interfaces:**
- Produces: `k8s/base/platform`, `k8s/base/backend`, `k8s/envs/local/backend`, `k8s/envs/dev/backend` — Task 2의 ArgoCD Application이 이 경로들을 `path`로 참조한다. Task 4는 `k8s/envs/<env>/backend`에서 `kustomize edit set image`를 돌리고, Task 5는 `k8s/envs/<env>/backend/game-server-config.env`를 sed한다.

- [ ] **Step 1: 재구성 전 렌더 결과를 기준선으로 저장**

이 파일들이 "정답"이다. 재구성 후 결과와 비교해 이식이 맞았는지 판정한다.

```bash
cd /Users/insoobae/workspace/LOP/.worktrees/infra-dev-env-gitops
mkdir -p /tmp/gitops-baseline
kubectl kustomize k8s/platform     > /tmp/gitops-baseline/platform.yaml
kubectl kustomize k8s/apps/backend > /tmp/gitops-baseline/backend.yaml
wc -l /tmp/gitops-baseline/*.yaml
```

기대: 두 파일 모두 0줄이 아님.

- [ ] **Step 2: 디렉터리 이동**

```bash
mkdir -p k8s/base
git mv k8s/platform     k8s/base/platform
git mv k8s/apps/backend k8s/base/backend
rmdir k8s/apps
```

- [ ] **Step 3: base에서 환경별 값 제거**

`k8s/base/backend/kustomization.yaml`을 아래 내용으로 만든다 (`game-server-config` 항목만 빠졌다):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - lobby-server
  - matchmaking-server
  - room-server
  - db-migrate
```

`k8s/base/backend/game-server-config/` 디렉터리를 통째로 삭제한다. 삭제 전에 `configmap.yaml`의 `GAME_SERVER_PUBLIC_IP` 위 주석(Windows IPv6 관련)을 Step 4에서 `.env`로 옮겨야 하니 먼저 읽어둔다.

```bash
git rm -r k8s/base/backend/game-server-config
```

네 앱의 kustomization에서 `images:` 블록을 지운다. 예를 들어 `k8s/base/backend/lobby-server/kustomization.yaml`은 이렇게 남는다:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- lobby-server-configmap.yaml
- lobby-server-deployment.yaml
- lobby-server-service.yaml
```

같은 방식으로 `matchmaking-server`(리소스 4개), `room-server`(리소스 4개), `db-migrate`(리소스 `job.yaml`)에서도 `images:` 3줄씩을 제거한다. **`resources:` 목록은 건드리지 않는다.**

- [ ] **Step 4: local 오버레이 생성**

`k8s/envs/local/backend/game-server-config.env`:

```properties
# 클라에게 알려줄 게임서버 접속 주소.
#
# "localhost"가 아니라 IPv4 리터럴이어야 한다. Windows에서 localhost는 ::1(IPv6)이 먼저
# 해석되고, kind가 호스트에 공개한 포트는 IPv4(0.0.0.0)뿐이다. 그래서 localhost를 주면
# 클라(kcp2k는 IPv6 소켓을 쓴다)가 [::1]로 붙어 ICMP port unreachable을 맞고 즉시 끊긴다.
# 실측: 127.0.0.1:7000 → 도달 / [::1]:7000 → ConnectionReset.
GAME_SERVER_IMAGE=re5nardo/game-server:6b4bb35
GAME_SERVER_PUBLIC_IP=127.0.0.1
```

`k8s/envs/local/backend/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - ../../../base/backend
images:
- name: re5nardo/lobby-server
  newName: re5nardo/lobby-server
  newTag: 9937c81
- name: re5nardo/matchmaking-server
  newName: re5nardo/matchmaking-server
  newTag: 9937c81
- name: re5nardo/room-server
  newName: re5nardo/room-server
  newTag: 9937c81
- name: re5nardo/lop-db-migrate
  newName: re5nardo/lop-db-migrate
  newTag: 9937c81
configMapGenerator:
- name: game-server-config
  envs:
  - game-server-config.env
```

> `images:` 블록의 들여쓰기·`newName` 중복은 `kustomize edit set image`가 쓰는 형식 그대로다. CI가 이 블록을 갱신하므로 형식을 바꾸지 않는다.

- [ ] **Step 5: dev 오버레이 생성**

`k8s/envs/dev/backend/game-server-config.env`:

```properties
# 클라에게 알려줄 게임서버 접속 주소. iwinv 노드의 공인 IP.
# room-server가 게임서버 파드를 만들 때 이 값 + NodePort를 클라에게 돌려준다.
GAME_SERVER_IMAGE=re5nardo/game-server:6b4bb35
GAME_SERVER_PUBLIC_IP=115.68.178.46
```

`k8s/envs/dev/backend/kustomization.yaml`은 **local과 완전히 동일한 내용**이다 (환경 차이는 `.env` 파일에만 있고, 태그는 CI가 환경별로 따로 bump하게 된다). Step 4의 kustomization 내용을 그대로 복사한다.

- [ ] **Step 6: 렌더 결과를 기준선과 비교**

```bash
kubectl kustomize k8s/base/platform     > /tmp/gitops-after-platform.yaml
kubectl kustomize k8s/envs/local/backend > /tmp/gitops-after-local.yaml
kubectl kustomize k8s/envs/dev/backend   > /tmp/gitops-after-dev.yaml

diff /tmp/gitops-baseline/platform.yaml /tmp/gitops-after-platform.yaml
diff /tmp/gitops-baseline/backend.yaml  /tmp/gitops-after-local.yaml
```

기대 결과:

1. **platform diff는 0줄이어야 한다.** 한 줄이라도 나오면 이동 중 뭔가 빠진 것이다.
2. **backend diff는 아래 두 종류만** 나와야 한다:
   - ConfigMap 이름: `name: game-server-config` → `name: game-server-config-<해시>`
   - room-server Deployment의 참조: `name: game-server-config` → `name: game-server-config-<해시>`
   - (생성기가 만든 ConfigMap이라 원본 YAML의 주석은 사라진다 — 렌더 출력에는 원래 주석이 없으므로 diff에 안 나온다)

이미지 태그·환경변수·리소스 개수에서 차이가 나면 이식이 틀린 것이니 고치고 다시 비교한다.

- [ ] **Step 7: dev 오버레이가 dev 값을 쓰는지 확인**

```bash
grep -A3 "GAME_SERVER" /tmp/gitops-after-dev.yaml
```

기대: `GAME_SERVER_PUBLIC_IP: 115.68.178.46`, `GAME_SERVER_IMAGE: re5nardo/game-server:6b4bb35`.

또한 local과 dev의 ConfigMap 해시가 **서로 달라야** 한다 (내용이 다르므로):

```bash
grep "name: game-server-config-" /tmp/gitops-after-local.yaml /tmp/gitops-after-dev.yaml
```

- [ ] **Step 8: 커밋**

```bash
git add -A
git commit -m "refactor(k8s): 매니페스트를 base + envs/{local,dev}로 분리

환경 차이(GAME_SERVER_PUBLIC_IP, 이미지 태그)를 환경 폴더 한 곳에 모은다.
game-server-config은 configMapGenerator로 바꿔 값이 바뀌면 이름 해시가 바뀌고
room-server 파드가 자동으로 롤링 재시작되게 했다 — 지금까지 수동 rollout restart가
필요하던 구멍을 막는다.

렌더 검증: platform diff 0, backend diff는 ConfigMap 이름 해시화 2곳뿐."
```

---

## Task 2: ArgoCD Application 정의를 환경별로 분리 + 문서 갱신

**레포:** infrastructure (같은 워크트리)

**Files:**
- Create: `k8s/argocd/envs/local/root-app.yaml`, `k8s/argocd/envs/local/apps/{platform,backend}.yaml`
- Create: `k8s/argocd/envs/dev/root-app.yaml`, `k8s/argocd/envs/dev/apps/{platform,backend}.yaml`
- Delete: `k8s/argocd/root-app.yaml`, `k8s/argocd/apps/`
- Modify: `README.md`, `k8s/argocd/README.md`, `k8s/argocd/install/README.md`

**Interfaces:**
- Consumes: Task 1이 만든 `k8s/base/platform`, `k8s/envs/{local,dev}/backend`
- Produces: `k8s/argocd/envs/local/root-app.yaml`(Task 3이 로컬 클러스터에 apply), `k8s/argocd/envs/dev/root-app.yaml`(Task 7이 iwinv에 apply)

- [ ] **Step 1: local용 Application 3종 작성**

`k8s/argocd/envs/local/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Baeinsoo/infrastructure
    targetRevision: main
    path: k8s/argocd/envs/local/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

`k8s/argocd/envs/local/apps/platform.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Baeinsoo/infrastructure
    targetRevision: main
    path: k8s/base/platform
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

`k8s/argocd/envs/local/apps/backend.yaml`: 위 platform.yaml과 동일하되 `name: backend`, `sync-wave: "1"`, `path: k8s/envs/local/backend`.

- [ ] **Step 2: dev용 Application 3종 작성**

`k8s/argocd/envs/dev/`에 같은 파일 3개를 만든다. local과 다른 곳은 **두 줄뿐**이다:

- `root-app.yaml`의 `path: k8s/argocd/envs/dev/apps`
- `apps/backend.yaml`의 `path: k8s/envs/dev/backend`

`apps/platform.yaml`은 local과 **완전히 동일**하다 (양쪽 다 `k8s/base/platform`을 본다).

- [ ] **Step 3: 옛 정의 제거**

```bash
git rm k8s/argocd/root-app.yaml
git rm -r k8s/argocd/apps
```

- [ ] **Step 4: 렌더 확인**

```bash
kubectl kustomize k8s/envs/local/backend > /dev/null && echo "local OK"
kubectl kustomize k8s/envs/dev/backend   > /dev/null && echo "dev OK"
for f in k8s/argocd/envs/*/root-app.yaml k8s/argocd/envs/*/apps/*.yaml; do
  kubectl apply --dry-run=client -f "$f" > /dev/null && echo "OK $f"
done
```

기대: 모든 줄이 OK. (`--dry-run=client`는 클러스터에 붙지 않고 스키마만 본다. Application CRD가 로컬 클러스터에 있으므로 kind-lop 컨텍스트에서 실행할 것.)

- [ ] **Step 5: 문서의 경로 갱신**

`README.md`에서 아래 문자열을 치환한다:

| 옛 경로 | 새 경로 |
|---|---|
| `k8s/apps/backend/<app>/kustomization.yaml` | `k8s/envs/<env>/backend/kustomization.yaml` |
| `k8s/apps/backend/game-server-config/configmap.yaml` | `k8s/envs/<env>/backend/game-server-config.env` |
| `k8s/platform` (ArgoCD가 관리하는 대상 문맥) | `k8s/base/platform` |
| `k8s/apps/backend` (같은 문맥) | `k8s/envs/<env>/backend` |
| `k8s/argocd/apps` | `k8s/argocd/envs/<env>/apps` |
| `kubectl apply -f k8s/argocd/root-app.yaml` | `kubectl apply -f k8s/argocd/envs/local/root-app.yaml` |

`k8s/local-k8s/...` 경로는 바뀌지 않았으니 그대로 둔다.

README의 디렉터리 트리(56행 부근)를 Task 1·2의 실제 구조로 고치고, 배포 파이프라인 설명(19·30행)에 **환경 선택 입력이 생긴다**는 점을 한 줄 덧붙인다.

`k8s/argocd/README.md`의 app-of-apps 설명도 같은 경로 규칙으로 고치고, **환경마다 별도 ArgoCD가 있다**는 사실과 두 환경의 path 대응표를 추가한다.

`k8s/argocd/install/README.md`는 제목이 "ArgoCD Install (local docker-desktop)"인데, 이제 두 클러스터에 설치하므로 **공통 절차 + 클러스터별 주의**로 고친다. iwinv 절차는 Task 6에서 채우므로 여기서는 로컬 부분만 정리하고 "iwinv는 Task 6 참고" 같은 미완성 문구를 남기지 않는다 — 대신 이 파일에 **클러스터 표**(컨텍스트 이름, root-app 경로)를 넣는다.

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "feat(argocd): Application 정의를 환경별로 분리

클러스터마다 자체 ArgoCD가 자기 환경 경로를 본다. Application 이름(root/platform/
backend)은 두 환경에서 동일하게 유지 — 이름이 바뀌면 옛 Application이 지워지면서
워크로드까지 캐스케이드 삭제된다."
```

---

## Task 3: main 머지 + 로컬 클러스터 전환

**레포:** infrastructure / **클러스터:** kind-lop

이 Task는 **로컬 클러스터를 실제로 전환**한다. 순서를 지키지 않으면 워크로드가 삭제될 수 있다.

**Interfaces:**
- Consumes: Task 1·2의 커밋
- Produces: main에 새 구조가 올라간 상태 — Task 4·5의 CI가 참조하는 경로가 이때부터 존재한다

- [ ] **Step 1: 위험 차단 — 옛 root Application의 자동 동기화를 끈다**

옛 root Application은 `k8s/argocd/apps`를 보고 있다. 머지되면 그 경로가 사라지는데, 만약 ArgoCD가 이를 "리소스 0개"로 해석하면 `prune: true`가 **`platform`/`backend` Application을 지우고 딸린 워크로드까지 캐스케이드 삭제**한다. 머지 전에 자동 동기화를 떼어낸다.

```bash
kubectl config use-context kind-lop
kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}'
kubectl -n argocd get application root -o jsonpath='{.spec.syncPolicy}'; echo
```

기대: 마지막 줄 출력이 비어 있음(syncPolicy 없음).

- [ ] **Step 2: main에 머지**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git checkout main && git pull
git merge --no-ff feature/dev-env-gitops -m "Merge feature/dev-env-gitops: base/envs 분리 + 환경별 ArgoCD 정의"
git push origin main
```

- [ ] **Step 3: 새 root-app 적용**

```bash
kubectl config use-context kind-lop
kubectl apply -f k8s/argocd/envs/local/root-app.yaml
kubectl -n argocd get application root -o jsonpath='{.spec.source.path}'; echo
```

기대: `k8s/argocd/envs/local/apps`

- [ ] **Step 4: 동기화 확인**

ArgoCD 폴링은 기본 3분이다. 기다리거나 강제로 새로고침한다.

```bash
kubectl -n argocd get applications
```

기대: `root`, `platform`, `backend` 세 개가 모두 `Synced` / `Healthy`. **Application이 3개 그대로여야 한다** — 이름이 사라졌거나 새 이름이 생겼으면 즉시 멈추고 조사한다.

`backend`의 path가 새 경로인지 확인:

```bash
kubectl -n argocd get application backend -o jsonpath='{.spec.source.path}'; echo
```

기대: `k8s/envs/local/backend`

- [ ] **Step 5: ConfigMap 해시화가 실제로 동작했는지 확인**

```bash
kubectl get configmap | grep game-server-config
kubectl get deploy room-server -o jsonpath='{.spec.template.spec.containers[0].envFrom[1].configMapRef.name}'; echo
kubectl get pods -l app=room-server
```

기대:
- ConfigMap 이름이 `game-server-config-<해시>` 하나 (옛 `game-server-config`는 prune으로 사라짐)
- Deployment의 참조가 그 해시 이름과 **일치**
- room-server 파드가 최근에 재시작되어 Running

- [ ] **Step 6: 서비스 동작 확인**

kind 클러스터는 hostPort 80 → 노드 31000으로 매핑돼 있어 `http://localhost/...`로 닿는다
(`k8s/local-k8s/kind-cluster.yaml`의 `extraPortMappings`).

```bash
for p in lobby matchmaking room; do
  printf "%s: " "$p"
  curl -s -o /dev/null -w "%{http_code}\n" "http://localhost/$p/"
done
```

기대: 세 줄 모두 200.

> README 143~145행이 `http://localhost:31000/...`로 적혀 있는데 이는 kind 전환 이전(Docker Desktop
> 시절)의 잔재로 보인다. 위 curl로 어느 쪽이 실제로 200을 주는지 확인하고, 틀린 쪽을 Task 2 Step 5의
> 문서 갱신에 포함시킨다.

- [ ] **Step 7: 워크트리 정리**

```bash
git worktree remove /Users/insoobae/workspace/LOP/.worktrees/infra-dev-env-gitops
git branch -d feature/dev-env-gitops
```

---

## Task 4: backend-deploy에 환경 선택 추가

**레포:** lop-backend (`/Users/insoobae/workspace/LOP/lop-backend`)

**Files:**
- Modify: `.github/workflows/backend-deploy.yml` (inputs 블록 + `bump-tags` job의 bump 스텝·커밋 메시지)

**Interfaces:**
- Consumes: Task 1이 만든 `k8s/envs/<env>/backend/kustomization.yaml`
- Produces: `environment` 입력(`local`/`dev`/`both`, 기본 `local`)을 가진 워크플로우

- [ ] **Step 1: 피처 브랜치 생성**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
git checkout main && git pull
git checkout -b feature/deploy-env-select
```

- [ ] **Step 2: `environment` 입력 추가**

`.github/workflows/backend-deploy.yml`의 `inputs:` 블록에 `app` 다음으로 추가한다:

```yaml
      environment:
        description: "배포 환경 (local=내 로컬 클러스터, dev=iwinv)"
        required: true
        default: local
        type: choice
        options: [local, dev, both]
```

- [ ] **Step 3: bump 스텝을 환경 폴더 기준으로 교체**

`bump-tags` job의 `이미지 태그 bump` 스텝 `run:` 본문을 아래로 교체한다. `DIR` 맵이 사라지고 환경 루프가 생긴 것이 핵심이다.

```bash
          set -e
          SHA="${{ steps.tag.outputs.sha }}"
          APP="${{ inputs.app }}"
          ENVIRONMENT="${{ inputs.environment }}"
          declare -A IMG=( [lobby-server]=re5nardo/lobby-server [matchmaking-server]=re5nardo/matchmaking-server [room-server]=re5nardo/room-server [db-migrate]=re5nardo/lop-db-migrate )
          if [ "$APP" = "all" ]; then
            targets=(lobby-server matchmaking-server room-server db-migrate)
          else
            targets=("$APP")
          fi
          if [ "$ENVIRONMENT" = "both" ]; then
            envs=(local dev)
          else
            envs=("$ENVIRONMENT")
          fi
          for env in "${envs[@]}"; do
            dir="k8s/envs/$env/backend"
            test -d "$dir" || { echo "환경 디렉터리 없음: $dir"; exit 1; }
            for app in "${targets[@]}"; do
              ( cd "$dir" && kustomize edit set image "${IMG[$app]}=${IMG[$app]}:${SHA}" )
              echo "bumped $env/$app -> ${IMG[$app]}:${SHA}"
            done
          done
```

- [ ] **Step 4: 커밋 메시지에 환경 남기기**

같은 job의 `commit + push` 스텝에서 커밋 메시지를 바꾼다:

```bash
            git commit -m "ci(deploy): bump backend image tags (${{ inputs.environment }}) -> ${{ steps.tag.outputs.sha }} [skip ci]"
```

- [ ] **Step 5: 워크플로우 문법 검증**

YAML이 파싱되는지, 그리고 bump 스크립트의 환경 분기가 의도대로 도는지 각각 확인한다.

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/backend-deploy.yml')); print('YAML OK')"
```

기대: `YAML OK`.

환경 분기는 워크플로우 문법(`${{ }}`)이 섞여 있어 그대로는 실행할 수 없으니, 같은 로직을 값만 넣어
따로 돌려본다.

```bash
for ENVIRONMENT in local dev both; do
  if [ "$ENVIRONMENT" = "both" ]; then envs=(local dev); else envs=("$ENVIRONMENT"); fi
  echo "$ENVIRONMENT -> ${envs[*]}"
done
```

기대: `local -> local`, `dev -> dev`, `both -> local dev`.

- [ ] **Step 6: 커밋 + 머지**

```bash
git add .github/workflows/backend-deploy.yml
git commit -m "ci(deploy): 배포 환경 선택 입력 추가 (local/dev/both)

infrastructure가 base+envs로 갈라지면서 태그 bump 대상이 앱별 폴더에서
환경 폴더 하나로 바뀌었다. 기본값은 안전한 local."
git checkout main && git merge --no-ff feature/deploy-env-select -m "Merge feature/deploy-env-select: 배포 환경 선택"
git push origin main
```

- [ ] **Step 7: 실제로 한 번 돌려 확인**

```bash
gh workflow run backend-deploy -R Baeinsoo/lop-backend -f app=all -f environment=local
```

완료 후 infrastructure main에 `ci(deploy): bump backend image tags (local) -> <sha>` 커밋이 생기고, **`k8s/envs/local/backend/kustomization.yaml`만** 바뀌었는지 확인한다:

```bash
cd /Users/insoobae/workspace/LOP/infrastructure && git pull && git show --stat HEAD
```

기대: 변경 파일이 `k8s/envs/local/backend/kustomization.yaml` 하나. dev 폴더가 함께 바뀌었으면 환경 루프가 잘못된 것이다.

---

## Task 5: gameserver-deploy에 환경 선택 추가

**레포:** LeagueOfPhysical-Server (`/Users/insoobae/workspace/LOP/LeagueOfPhysical-Server`)

**Files:**
- Modify: `.github/workflows/gameserver-deploy.yml` (`on:` 블록에 inputs 신설 + `infra game-server-config 태그 bump` 스텝)

**Interfaces:**
- Consumes: Task 1이 만든 `k8s/envs/<env>/backend/game-server-config.env`

- [ ] **Step 1: 피처 브랜치 생성**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
git checkout main && git pull
git checkout -b feature/deploy-env-select
```

- [ ] **Step 2: 입력 추가**

`.github/workflows/gameserver-deploy.yml`의 맨 위 `on:` 블록을 교체한다 (현재는 입력이 하나도 없다):

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        description: "배포 환경 (local=내 로컬 클러스터, dev=iwinv)"
        required: true
        default: local
        type: choice
        options: [local, dev, both]
```

- [ ] **Step 3: sed 대상을 환경별 .env 파일로 교체**

`infra game-server-config 태그 bump` 스텝에서 `CM=...` 줄과 `sed` 줄을 아래로 교체한다. 나머지(클론·트랩·커밋 조건)는 그대로 둔다.

```bash
          if [ "${{ inputs.environment }}" = "both" ]; then
            envs=(local dev)
          else
            envs=("${{ inputs.environment }}")
          fi
          for env in "${envs[@]}"; do
            F="k8s/envs/$env/backend/game-server-config.env"
            test -f "$F" || { echo "환경 파일 없음: $F"; exit 1; }
            # BSD sed (맥 러너). KEY=value 라인의 값만 교체한다.
            sed -i '' -E "s|(GAME_SERVER_IMAGE=).*|\\1re5nardo/game-server:${{ steps.tag.outputs.sha }}|" "$F"
            echo "bumped $env -> re5nardo/game-server:${{ steps.tag.outputs.sha }}"
          done
```

커밋 메시지도 환경을 남기게 바꾼다:

```bash
            git commit -am "ci(gameserver): bump GAME_SERVER_IMAGE (${{ inputs.environment }}) -> ${{ steps.tag.outputs.sha }} [skip ci]"
```

- [ ] **Step 4: sed 표현식을 실제 파일로 검증**

워크플로우를 돌리기 전에 sed가 맞는 줄만 바꾸는지 로컬에서 확인한다.

```bash
cd /Users/insoobae/workspace/LOP/infrastructure && git pull
cp k8s/envs/dev/backend/game-server-config.env /tmp/gs-test.env
sed -i '' -E "s|(GAME_SERVER_IMAGE=).*|\1re5nardo/game-server:TESTSHA|" /tmp/gs-test.env
diff k8s/envs/dev/backend/game-server-config.env /tmp/gs-test.env
```

기대: `GAME_SERVER_IMAGE` 줄 하나만 다르고, `GAME_SERVER_PUBLIC_IP`와 주석은 그대로.

- [ ] **Step 5: 문법 검증 + 커밋 + 머지**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/gameserver-deploy.yml')); print('YAML OK')"
git add .github/workflows/gameserver-deploy.yml
git commit -m "ci(gameserver): 배포 환경 선택 입력 추가 (local/dev/both)

GAME_SERVER_IMAGE가 환경별 game-server-config.env로 옮겨가면서 sed 대상이
YAML에서 KEY=value 파일로 바뀌었다."
git checkout main && git merge --no-ff feature/deploy-env-select -m "Merge feature/deploy-env-select: 배포 환경 선택"
git push origin main
```

> 이 워크플로우는 Unity IL2CPP 빌드라 실행에 오래 걸린다. 실제 실행 검증은 Task 7의 마지막 단계에서 dev 대상으로 한 번 돌리는 것으로 갈음한다.

---

## Task 6: iwinv 현황 점검 + ArgoCD 설치 + 시크릿 부트스트랩

**대상:** iwinv 라이브 서버 (`ssh -i ~/.ssh/iwinv_lop root@115.68.178.46`)

⚠️ **이 Task를 시작하기 전에 사용자 확인을 받는다.** 라이브 서버에 소프트웨어를 설치한다.

**Interfaces:**
- Produces: iwinv에 동작하는 ArgoCD + 시크릿 2종 — Task 7이 root-app을 apply할 수 있는 상태

- [ ] **Step 1: 현황 점검 (읽기 전용)**

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl get nodes
  echo "--- deployments ---"; kubectl get deploy -A
  echo "--- 이미지 ---"; kubectl get deploy -o jsonpath="{range .items[*]}{.metadata.name}{\"\t\"}{.spec.template.spec.containers[0].image}{\"\n\"}{end}"
  echo "--- secrets ---"; kubectl get secret
  echo "--- configmaps ---"; kubectl get cm
  echo "--- argocd 존재? ---"; kubectl get ns argocd 2>&1 | tail -1
  echo "--- 여유 자원 ---"; free -m; df -h /
'
```

결과를 기록한다. 특히 다음을 확인한다:
- `auth-secret` / `internal-api-secret`이 이미 있는가 (없으면 Step 4에서 만든다)
- mongodb 등 지금 레포에 없는 잔재가 떠 있는가 (Task 7 Step 4에서 정리)
- 메모리 여유가 ArgoCD(약 1GB)를 받을 수 있는가

- [ ] **Step 2: 게임서버 이미지 미리 캐시**

현재 dev가 가리킬 게임서버 이미지를 미리 pull 해둔다. 첫 pull이 heartbeat 임계(10초)를 넘기면 게임서버 파드가 부팅 전에 회수된다.

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 \
  'crictl pull re5nardo/game-server:6b4bb35 && crictl images | grep game-server'
```

- [ ] **Step 3: ArgoCD 설치**

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
  kubectl wait --for=condition=available --timeout=300s deployment -n argocd \
    argocd-server argocd-repo-server argocd-applicationset-controller
  kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
  kubectl get pods -n argocd
'
```

기대: 7개 파드 모두 Running.

메모리 압박이 관측되면(Step 1의 `free -m` 대비) 로그인에 필요 없는 두 컴포넌트를 끈다:

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl -n argocd scale deploy argocd-dex-server --replicas=0
  kubectl -n argocd scale deploy argocd-notifications-controller --replicas=0
'
```

- [ ] **Step 4: 시크릿 2종 생성 (Sync 이전에 반드시)**

Step 1에서 이미 존재하는 것으로 확인됐다면 건너뛴다. 없다면:

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl get secret auth-secret >/dev/null 2>&1 || \
    kubectl create secret generic auth-secret \
      --from-literal=AUTH_JWT_SECRET="$(openssl rand -base64 32)"
  kubectl get secret internal-api-secret >/dev/null 2>&1 || \
    kubectl create secret generic internal-api-secret \
      --from-literal=INTERNAL_API_KEY="$(openssl rand -base64 32)"
  kubectl get secret
'
```

두 값은 **서로 다른 Secret**이어야 한다 (서명키와 조회키 분리 — 게임서버 파드에는 조회키만 간다).

- [ ] **Step 5: ArgoCD 접근 확인**

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 \
  "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

UI가 필요하면 SSH 터널로만 연다 (인그레스에 얹지 않는다):

```bash
ssh -i ~/.ssh/iwinv_lop -L 8080:localhost:8080 root@115.68.178.46 \
  'kubectl port-forward -n argocd svc/argocd-server 8080:443'
```

- [ ] **Step 6: 설치 절차를 문서에 남긴다**

infrastructure 레포에 새 피처 브랜치를 만들고 `k8s/argocd/install/README.md`에 **iwinv(dev) 설치 절차**를 위 Step 3~5 내용으로 추가한다. 접속 IP·SSH 키 경로·NodePort(31000)를 명시한다. 커밋:

```bash
git commit -m "docs(argocd): iwinv(dev) 클러스터 설치 절차 추가"
```

---

## Task 7: iwinv에 root-app 등록 + 잔재 정리 + 최종 검증

**대상:** iwinv 라이브 서버

⚠️ **이 Task를 시작하기 전에 사용자 확인을 받는다.** 라이브 서비스가 새 매니페스트로 롤링되며 짧은 다운타임이 생긴다.

**Interfaces:**
- Consumes: Task 2의 `k8s/argocd/envs/dev/root-app.yaml`(이미 main에 있음), Task 6의 ArgoCD·시크릿

- [ ] **Step 1: root-app 적용**

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl apply -f https://raw.githubusercontent.com/Baeinsoo/infrastructure/main/k8s/argocd/envs/dev/root-app.yaml
  kubectl -n argocd get applications
'
```

기대: `root` Application 생성. 잠시 후 `platform`, `backend`가 자동 생성된다.

- [ ] **Step 2: 동기화 대기 및 확인**

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl -n argocd get applications
  kubectl get pods
'
```

기대: 세 Application 모두 `Synced`/`Healthy`, 파드가 모두 Running.

`CrashLoopBackOff`가 보이면 로그를 본다 — 시크릿 누락이 가장 흔한 원인이다.

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 'kubectl logs deploy/lobby-server --tail=50'
```

- [ ] **Step 3: dev 값이 실제로 적용됐는지 확인**

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl get cm | grep game-server-config
  kubectl get cm -o yaml | grep -A2 GAME_SERVER_PUBLIC_IP
'
```

기대: `game-server-config-<해시>` 하나, `GAME_SERVER_PUBLIC_IP: 115.68.178.46`. **127.0.0.1이 보이면 즉시 멈춘다** — dev가 local 오버레이를 보고 있다는 뜻이다.

- [ ] **Step 4: 잔재 정리**

Task 6 Step 1에서 발견한, 지금 레포에 없는 리소스(mongodb 등)를 지운다. ArgoCD가 만든 게 아니라 `prune` 대상이 아니므로 남아 있다.

**지우기 전에 사용자에게 목록을 보여주고 확인받는다.** 예시:

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl delete deploy mongodb --ignore-not-found
  kubectl delete svc mongodb --ignore-not-found
  kubectl delete pvc mongodb-pvc --ignore-not-found
'
```

- [ ] **Step 5: 공개 API 확인**

```bash
for p in lobby matchmaking room; do
  printf "%s: " "$p"
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 6 "http://115.68.178.46:31000/$p/"
done
```

기대: 세 줄 모두 200.

- [ ] **Step 6: 게임서버 스폰 E2E**

서버에 저장돼 있는 기존 스크립트를 쓴다. Room의 `matchId`가 unique라 재실행 전 정리가 필요하다.

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  bash /root/e2e.sh
  kubectl get pods | grep game-server
'
```

기대: 게임서버 파드가 Running으로 60초 이상 유지되고, room-server 응답에 `room.ip=115.68.178.46`과 NodePort가 담긴다.

- [ ] **Step 7: 이 작업의 핵심 개선 검증 — ConfigMap 변경이 파드를 재시작시키는가**

게임서버 워크플로우를 dev 대상으로 한 번 돌린다 (Task 5의 실동작 검증도 겸한다).

```bash
gh workflow run gameserver-deploy -R Baeinsoo/LeagueOfPhysical-Server -f environment=dev
```

빌드·푸시·bump 완료 후 (Unity 빌드라 오래 걸린다) infra main에 `ci(gameserver): bump GAME_SERVER_IMAGE (dev) -> <sha>` 커밋이 생기는지 확인하고, ArgoCD 폴링(약 3분) 뒤:

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl get cm | grep game-server-config
  kubectl get pods -l app=room-server
  kubectl exec deploy/room-server -- printenv GAME_SERVER_IMAGE
'
```

기대:
- ConfigMap 해시 이름이 **바뀌어 있음**
- room-server 파드의 AGE가 **방금 재시작된 값** (사람이 `rollout restart`를 치지 않았는데도)
- `printenv` 결과가 **새 sha**

이 세 가지가 모두 맞으면, 메모리에 기록된 "gameserver-deploy 먼저, backend-deploy 나중에" 관행이 더 이상 필요 없다.

- [ ] **Step 8: 롤백 절차 확인 (실행하지 않고 문서화만)**

`k8s/argocd/install/README.md` 또는 `README.md`에 dev 롤백 절차를 적는다:

- 매니페스트 롤백: infrastructure main에서 해당 커밋 `git revert` → 약 3분 내 ArgoCD가 되돌림
- GitOps 자체를 되돌리기: `kubectl delete application root platform backend -n argocd --cascade=orphan` — Application만 지우고 워크로드는 그대로 남는다

- [ ] **Step 9: 메모리 갱신**

`~/.claude/projects/-Users-insoobae-workspace-LOP/memory/iwinv-test-deployment.md`를 고친다. 지금 그 파일은 "수동 rsync + `kubectl apply -k`, `:latest` 이미지"라고 적혀 있는데 이 작업으로 사실이 아니게 된다. 배포 경로가 GitOps로 바뀌었고, ConfigMap 재시작 예외가 해소됐다는 점을 반영한다.

`~/.claude/projects/-Users-insoobae-workspace-LOP-lop-backend/memory/iwinv-deployment-pointer.md`의 "ArgoCD GitOps 경로가 아니며 이미지도 sha 태그가 아닌 `:latest`를 쓴다"는 문장도 함께 고친다.

---

## 완료 기준

- [ ] 로컬·iwinv 두 클러스터의 ArgoCD가 모두 `Synced`/`Healthy`
- [ ] `curl http://115.68.178.46:31000/{lobby,matchmaking,room}/` → 200
- [ ] dev의 `GAME_SERVER_PUBLIC_IP`가 `115.68.178.46`, local은 `127.0.0.1`
- [ ] 게임서버 태그만 바꾼 커밋에 iwinv room-server 파드가 **자동 재시작**
- [ ] E2E: Match INSERT → 게임서버 파드 스폰 + heartbeat 정상
- [ ] `backend-deploy -f environment=local` 실행 시 dev 폴더가 바뀌지 않음
- [ ] 메모리·README가 새 현실을 반영
