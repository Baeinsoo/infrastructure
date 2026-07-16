# Phase 1: infrastructure 개편 + ArgoCD 도입 (greenfield) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 흩어진 k8s 매니페스트를 infrastructure 레포로 집결(Kustomize)하고, 로컬 클러스터에 ArgoCD를 설치한다. 기존에 떠 있던 leftover 리소스는 전부 내리고, **빈 상태에서 ArgoCD가 매니페스트대로 새로 배포**한다(greenfield). DB 마이그레이션은 PreSync Job으로 자동화한다.

**Architecture:** infrastructure 레포가 배포의 단일 진실. `k8s/platform/`(DB·Redis·Ingress·RBAC) + `k8s/apps/backend/`(서버 3종 + db-migrate PreSync Job) + `k8s/argocd/`(app-of-apps). ArgoCD는 `argocd` ns, 앱 리소스는 `default` ns. app-of-apps에 sync-wave를 걸어 platform(DB) → backend(앱) 순서로 올라오고, migrate Job은 DB 준비를 기다린다.

**Tech Stack:** kubectl 내장 Kustomize (`kubectl apply -k`), ArgoCD v2.13.2 공식 install manifest, docker-desktop 단일 노드 k8s v1.32.2.

**설계 문서:** `infrastructure/docs/specs/2026-07-05-deployment-system-design.md`

---

## Global Constraints

**결정 사항 (2026-07-05, 사용자 확정):**
- 기존에 302일째 떠 있던 pod/DB는 **예전 작업 잔여물**이다. 보존 불필요 → **전부 teardown 후 ArgoCD로 새로 배포**(greenfield). 인수(adopt)·무중단 고려 없음.
- 따라서 ArgoCD는 처음부터 **automated sync (prune: true, selfHeal: true)** 사용 가능.

**현재 클러스터 사실 (조사 확정):**
- 컨텍스트 `docker-desktop`, 단일 노드, k8s v1.32.2.
- teardown 대상(default ns leftover): Deploy `lobby-server`/`matchmaking-server`/`room-server`/`postgres-deployment`/`mongodb-deployment`/`redis-deployment`, 대응 Service들, PVC `postgres-pvc`/`mongodb-pvc`, SA `room-server` + room RBAC, Ingress `lop-ingress`.
- **teardown 제외(보존)**: `ingress-nginx` 네임스페이스의 컨트롤러(v1.12.0-beta.0, NodePort 31000/32000) — 부트스트랩 컴포넌트, ArgoCD 관리 밖.
- 이미지: 앱 3종 `re5nardo/{lobby,matchmaking,room}-server:latest`는 **Docker Hub에 존재**(구 pre-monorepo 코드). `re5nardo/lop-db-migrate:latest`는 **없음 → Phase 1에서 빌드·푸시**.
- DB 마이그레이션: `@lop/database`에 `20250902145642_init` 마이그레이션 존재. 빈 DB에 `migrate deploy` 시 처음부터 적용됨. `seed.ts`는 `upsert` 멱등.

**불변 규칙:**
1. 네임스페이스는 `default`(앱·DB), `argocd`(ArgoCD), `ingress-nginx`(기존 컨트롤러). 새 ns 도입 없음.
2. Phase 1 이미지 태그는 `:latest` (앱은 기존 Docker Hub 이미지, db-migrate는 새로 push). **sha 태깅은 Phase 2(CI)**. 앱은 Phase 2 CI가 모노레포 이미지를 올리기 전까지 구 코드로 동작한다(배포 메커니즘 검증이 Phase 1 목표).
3. 매니페스트 이관 시 리소스 이름·셀렉터·포트·envFrom 참조는 기존값과 1:1 유지 (재작성 아님, 이동).
4. 커밋은 infrastructure 레포(`main`, remote `github.com/Baeinsoo/infrastructure`). **ArgoCD는 원격에서 매니페스트를 읽으므로, sync 대상 커밋은 반드시 push 되어 있어야 한다.**
5. teardown(`kubectl delete`) 같은 파괴적 명령은 대상 네임스페이스·리소스를 명시적으로 한정 (`ingress-nginx`, `argocd`, `kube-system` 절대 건드리지 않음).

**검증 도구:** `kubectl kustomize <dir>` (렌더), `kubectl get application -n argocd`, `kubectl get pods -n default`.

---

### Task 1: infrastructure 레포 디렉토리 재구성 + platform Kustomize

기존 `k8s/local-k8s/`의 매니페스트를 의미 그룹으로 나눠 `k8s/platform/`로 재배치하고 kustomization을 얹는다. **파일 이동(git mv)만, 내용 변경 없음.**

**Files:**
- Create: `k8s/platform/{postgres,mongodb,redis,ingress,rbac}/kustomization.yaml`, `k8s/platform/kustomization.yaml`, `k8s/platform/ingress/README.md`
- Move (git mv): `k8s/local-k8s/*` → 해당 하위 디렉토리 (단 `ingress-nginx-deploy.yaml`은 `local-k8s/`에 잔류)

**Interfaces:**
- Produces: `kubectl kustomize k8s/platform`가 postgres/mongo/redis/ingress/rbac 전부 렌더. Task 6의 platform Application이 이 경로를 가리킴.

- [ ] **Step 1: 디렉토리 생성 + git mv**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure/k8s
mkdir -p platform/{postgres,mongodb,redis,ingress,rbac}
git mv local-k8s/postgres-*.yaml platform/postgres/
git mv local-k8s/mongodb-*.yaml  platform/mongodb/
git mv local-k8s/redis-*.yaml    platform/redis/
git mv local-k8s/ingress.yaml    platform/ingress/
# RBAC (실제 파일명은 ls로 확인 후 조정): namespace-*/pod-*/service-* role/clusterrole/binding 전부
ls local-k8s/    # 남은 파일 파악
for f in $(ls local-k8s/ | grep -iE 'role|reader|creator|deleter|binding'); do git mv "local-k8s/$f" platform/rbac/; done
ls local-k8s/ platform/*/
```
Expected: `local-k8s/`에 `ingress-nginx-deploy.yaml`(+`.DS_Store`)만 잔류. platform 하위에 postgres 4 / mongo 3 / redis 2 / ingress 1 / rbac 14개 이동. (파일명이 glob과 안 맞으면 `ls`로 확인 후 개별 `git mv`.)

- [ ] **Step 2: 하위 디렉토리 kustomization.yaml (실제 파일명으로 resources 작성)**

각 디렉토리에서 `ls`로 파일명 확인 후:
`k8s/platform/postgres/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - postgres-secret.yaml
  - postgres-pvc.yaml
  - postgres-deployment.yaml
  - postgres-service.yaml
```
동일하게 `mongodb/`(pvc, deployment, service), `redis/`(deployment, service), `ingress/`(ingress.yaml), `rbac/`(이동된 14개 전부 나열).

- [ ] **Step 3: platform 묶음 kustomization.yaml**

`k8s/platform/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - postgres
  - mongodb
  - redis
  - ingress
  - rbac
```
(ClusterRole/ClusterRoleBinding은 클러스터 스코프라 `namespace: default`에 영향받지 않음 — 정상.)

- [ ] **Step 4: 렌더 검증**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
kubectl kustomize k8s/platform > /tmp/platform-rendered.yaml && echo "RENDER OK ($(grep -c '^kind:' /tmp/platform-rendered.yaml) resources)"
grep -E '^(kind|  name):' /tmp/platform-rendered.yaml | head -60
```
Expected: RENDER OK. postgres/mongo/redis Deployment+Service, PVC 2개, Secret 1개, ingress 1개, RBAC 14개가 렌더 결과에 보임. (아직 클러스터 적용 안 함 — Task 6에서.)

- [ ] **Step 5: ingress-nginx 취급 문서화**

`k8s/platform/ingress/README.md`:
```markdown
# ingress-nginx 컨트롤러

컨트롤러(`../../local-k8s/ingress-nginx-deploy.yaml`, v1.12.0-beta.0)는 이미 클러스터의
`ingress-nginx` 네임스페이스에 설치되어 NodePort 31000(HTTP)/32000(HTTPS)로 동작 중이다.
부트스트랩 컴포넌트이므로 ArgoCD 관리 대상이 아니다(teardown 대상도 아님).
이 디렉토리의 `ingress.yaml`(lop-ingress 라우팅)만 ArgoCD(platform)가 관리한다.
재설치 필요 시: kubectl apply -f k8s/local-k8s/ingress-nginx-deploy.yaml
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(k8s): platform 매니페스트를 Kustomize 구조로 재배치 (내용 불변)"
```

---

### Task 2: 앱 매니페스트 집결 + room RBAC 정리 + db-migrate Job

서버 3종 매니페스트를 `k8s/apps/backend/`로 모으고, room SA를 가져오며 중복 RBAC를 정리한다. greenfield이므로 db-migrate PreSync Job도 처음부터 포함한다.

**Files:**
- Create: `k8s/apps/backend/{lobby,matchmaking,room}-server/*.yaml` + 각 `kustomization.yaml`, `k8s/apps/backend/room-server/serviceaccount.yaml`, `k8s/apps/backend/db-migrate/{job.yaml,kustomization.yaml}`, `k8s/apps/backend/kustomization.yaml`

**Interfaces:**
- Consumes: platform의 `postgres-secret`, platform/rbac(room 권한)
- Produces: `kubectl kustomize k8s/apps/backend` 렌더. Task 6의 backend Application이 이 경로.

- [ ] **Step 1: 앱 매니페스트 복사**

```bash
cd /Users/insoobae/workspace/LOP
mkdir -p infrastructure/k8s/apps/backend/{lobby-server,matchmaking-server,room-server,db-migrate}
cp LeagueOfPhysical-LobbyServer/LobbyServer/k8s/local-k8s/*.yaml            infrastructure/k8s/apps/backend/lobby-server/
cp LeagueOfPhysical-MatchmakingServer/MatchmakingServer/k8s/local-k8s/*.yaml infrastructure/k8s/apps/backend/matchmaking-server/
cp LeagueOfPhysical-RoomServer/RoomServer/k8s/local-k8s/*.yaml              infrastructure/k8s/apps/backend/room-server/
ls infrastructure/k8s/apps/backend/*/
```

- [ ] **Step 2: room RBAC 중복 제거 (SA만 유지)**

room 레포의 `room-server-rbac.yaml`(`room-server-role` + binding, default ns pods/services 조작)은 platform/rbac의 세분화 세트(namespace-creator/reader, pod/service reader/creator/deleter + bindings, 전부 SA `room-server`에 바인딩)의 **부분집합**이다. platform 세트가 상위집합(namespace 생성 권한까지 포함)이므로 room의 중복 Role/RoleBinding은 제거하고 ServiceAccount만 남긴다.

```bash
cd /Users/insoobae/workspace/LOP/infrastructure/k8s/apps/backend/room-server
rm -f room-server-rbac.yaml
mv room-server-serviceaccount.yaml serviceaccount.yaml 2>/dev/null || true
ls   # configmap, deployment, service, serviceaccount 남아야 함
```

- [ ] **Step 3: 앱별 kustomization.yaml (images 블록 = Phase 2 태그 bump 지점)**

`k8s/apps/backend/lobby-server/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - lobby-server-configmap.yaml
  - lobby-server-deployment.yaml
  - lobby-server-service.yaml
images:
  - name: re5nardo/lobby-server
    newTag: latest
```
matchmaking 동일. room은 resources에 `serviceaccount.yaml` 추가 + images `re5nardo/room-server`.

- [ ] **Step 4: db-migrate PreSync Job (DB 준비 대기 initContainer 포함)**

`k8s/apps/backend/db-migrate/job.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: default
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: wait-for-postgres
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -z postgres-service 5432; do echo "waiting for postgres..."; sleep 2; done']
      containers:
        - name: db-migrate
          image: re5nardo/lop-db-migrate:latest
          imagePullPolicy: Always
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: POSTGRES_PASSWORD
            - name: DATABASE_URL
              value: "postgresql://postgres:$(POSTGRES_PASSWORD)@postgres-service:5432/postgres?schema=public"
```
설명: `hook: PreSync` = backend sync의 리소스 적용 직전 실행. initContainer가 `postgres-service:5432` 열릴 때까지 대기 → platform이 먼저 떠 있어도/막 떴어도 DB 준비 후 마이그레이션. `hook-delete-policy: BeforeHookCreation` = 다음 실행 직전 이전 Job 정리(이력 1개). CMD는 이미지 기본값 `migrate:deploy && seed`.

`k8s/apps/backend/db-migrate/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - job.yaml
images:
  - name: re5nardo/lop-db-migrate
    newTag: latest
```

- [ ] **Step 5: backend 묶음 kustomization.yaml**

`k8s/apps/backend/kustomization.yaml`:
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

- [ ] **Step 6: 렌더 검증**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
kubectl kustomize k8s/apps/backend > /tmp/backend-rendered.yaml && echo "RENDER OK"
grep -E '^(kind|  name):|hook:' /tmp/backend-rendered.yaml
```
Expected: 3 Deployment + 3 Service + 3 ConfigMap + 1 ServiceAccount + 1 Job(PreSync hook 어노테이션 포함) 렌더.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(k8s): 서버 3종 + db-migrate PreSync Job 집결, room RBAC 정리"
```

---

### Task 3: db-migrate 이미지 빌드 + 푸시

PreSync Job이 pull할 `re5nardo/lop-db-migrate:latest`가 레지스트리에 없으므로 빌드·푸시한다. (Phase 0 Dockerfile 사용. Phase 2 CI가 이후 sha 태깅 자동화.)

**Files:** 없음 (레지스트리 작업)

- [ ] **Step 1: Docker Hub 인증 확인**

```bash
docker info 2>/dev/null | grep -i username || echo "not logged in — 'docker login' 필요 (사용자에게 요청: ! docker login)"
```
로그인 안 돼 있으면 사용자에게 `! docker login` 실행 요청 후 진행.

- [ ] **Step 2: 빌드 + 푸시**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
docker build -f packages/database/Dockerfile -t re5nardo/lop-db-migrate:latest .
docker push re5nardo/lop-db-migrate:latest
```
Expected: 빌드 성공(Phase 0 Task 6에서 이미 검증된 Dockerfile), push 성공.

- [ ] **Step 3: 레지스트리 확인**

```bash
docker manifest inspect re5nardo/lop-db-migrate:latest >/dev/null 2>&1 && echo "PUSHED OK"
for img in re5nardo/lobby-server:latest re5nardo/matchmaking-server:latest re5nardo/room-server:latest; do docker manifest inspect "$img" >/dev/null 2>&1 && echo "app image present: $img"; done
```
Expected: db-migrate PUSHED OK, 앱 이미지 3종 present (기존 Docker Hub 이미지 — greenfield 배포가 pull).

---

### Task 4: ArgoCD 설치

**Files:**
- Create: `k8s/argocd/install/README.md`

**Interfaces:**
- Produces: `argocd` ns에 기동한 ArgoCD. Task 6이 Application CR을 apply.

- [ ] **Step 1: 설치**

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
```

- [ ] **Step 2: 기동 대기**

```bash
kubectl wait --for=condition=available --timeout=300s deployment -n argocd argocd-server argocd-repo-server argocd-applicationset-controller
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl get pods -n argocd
```
Expected: 전부 Running.

- [ ] **Step 3: 접속 확인 + admin 비밀번호**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward -n argocd svc/argocd-server 8080:443 >/dev/null 2>&1 &
sleep 4; curl -sk https://localhost:8080/healthz && echo " <- healthy"; kill %1 2>/dev/null
```
Expected: 비밀번호 출력, `/healthz` → ok. (접속 https://localhost:8080, user admin.)

- [ ] **Step 4: 버전 기록 + Commit**

`k8s/argocd/install/README.md` 작성 (버전 v2.13.2, 설치 명령, 접속·비번 절차).
```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git add -A && git commit -m "docs(argocd): ArgoCD v2.13.2 설치 및 접속 절차"
```

---

### Task 5: 기존 leftover 리소스 teardown

ArgoCD 새 배포 전에 default ns의 예전 잔여 리소스를 정리해 빈 상태를 만든다. **`ingress-nginx`/`argocd`/`kube-*` 네임스페이스는 절대 건드리지 않는다.**

**Files:** 없음 (클러스터 작업)

- [ ] **Step 1: 삭제 대상 확인 (dry-run 성격)**

```bash
kubectl get deploy,svc,pvc,sa,ingress,role,rolebinding -n default
kubectl get clusterrole,clusterrolebinding | grep -E 'namespace-|pod-|service-' 
```
Expected: teardown 대상 목록 확인 (앱 3 + DB 3 Deploy, 대응 Service, PVC 2, SA room-server, lop-ingress, room RBAC).

- [ ] **Step 2: default ns 워크로드 + PVC 삭제**

```bash
kubectl delete deployment lobby-server matchmaking-server room-server postgres-deployment mongodb-deployment redis-deployment -n default --ignore-not-found
kubectl delete service lobby-server-service matchmaking-server-service room-server-service postgres-service mongodb-service redis-service -n default --ignore-not-found
kubectl delete pvc postgres-pvc mongodb-pvc -n default --ignore-not-found
kubectl delete ingress lop-ingress -n default --ignore-not-found
kubectl delete serviceaccount room-server -n default --ignore-not-found
kubectl delete configmap lobby-server-config matchmaking-server-config room-server-config -n default --ignore-not-found
```

- [ ] **Step 3: room 관련 기존 RBAC 삭제 (ArgoCD가 새로 만들 것)**

```bash
kubectl delete role room-server-role pod-creator pod-deleter service-creator service-deleter -n default --ignore-not-found
kubectl delete rolebinding room-server-rolebinding pod-creator-rolebinding pod-deleter-rolebinding service-creator-rolebinding service-deleter-rolebinding -n default --ignore-not-found
kubectl delete clusterrole namespace-creator namespace-reader pod-reader service-reader --ignore-not-found
kubectl delete clusterrolebinding namespace-creator-binding namespace-reader-binding pod-reader-rolebinding service-reader-rolebinding --ignore-not-found
```
(정확한 이름은 Task 5 Step 1 출력 기준. 다르면 조정.)

- [ ] **Step 4: 정리 확인**

```bash
kubectl get all -n default        # kubernetes service 외엔 비어야 함
kubectl get pvc -n default        # 비어야 함
kubectl get ns                    # ingress-nginx, argocd, kube-* 는 그대로
```
Expected: default ns가 `service/kubernetes`만 남고 깨끗. ingress-nginx/argocd 네임스페이스 유지.

---

### Task 6: ArgoCD Application (app-of-apps) — greenfield 배포

app-of-apps 루트 + platform/backend Application을 만들고, sync-wave로 platform(DB) → backend(앱) 순서 배포. automated sync(prune+selfHeal)로 빈 클러스터에 전체를 새로 올린다.

**Files:**
- Create: `k8s/argocd/apps/{platform,backend}.yaml`, `k8s/argocd/root-app.yaml`, `k8s/argocd/README.md`

**Interfaces:**
- Consumes: Task 1·2의 `k8s/platform`, `k8s/apps/backend` (원격 레포). 반드시 push 후 sync.
- Produces: ArgoCD가 배포·관리하는 전체 스택.

- [ ] **Step 1: platform Application (sync-wave 0)**

`k8s/argocd/apps/platform.yaml`:
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
    path: k8s/platform
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

- [ ] **Step 2: backend Application (sync-wave 1)**

`k8s/argocd/apps/backend.yaml` — platform과 동일 구조, `name: backend`, `sync-wave: "1"`, `path: k8s/apps/backend`, 동일 automated 정책.
(sync-wave로 platform이 먼저 적용되고, backend의 db-migrate PreSync Job은 initContainer로 postgres 준비를 추가로 기다림 — 이중 안전.)

- [ ] **Step 3: app-of-apps 루트**

`k8s/argocd/root-app.yaml`:
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
    path: k8s/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Commit + push (sync 전 필수)**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git add -A && git commit -m "feat(argocd): app-of-apps (platform wave0 / backend wave1) greenfield 배포"
git push origin main
```

- [ ] **Step 5: (private 레포면) repo credential 등록**

```bash
gh repo view Baeinsoo/infrastructure --json visibility -q .visibility
```
`PRIVATE`이면:
```bash
kubectl -n argocd create secret generic infra-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/Baeinsoo/infrastructure \
  --from-literal=username=<github-user> \
  --from-literal=password=<PAT repo:read>
kubectl -n argocd label secret infra-repo argocd.argoproj.io/secret-type=repository
```
`PUBLIC`이면 생략.

- [ ] **Step 6: 루트 apply → 전체 배포**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
kubectl apply -f k8s/argocd/root-app.yaml
# 배포가 안정될 때까지 bounded 폴링 (최대 ~5분, -w 대신)
for i in $(seq 1 30); do
  echo "--- poll $i ---"; kubectl get applications -n argocd 2>/dev/null
  READY=$(kubectl get application backend -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  echo "backend: $READY"; kubectl get pods -n default 2>/dev/null | grep -vE 'Completed'
  [ "$READY" = "Synced/Healthy" ] && echo "DEPLOY SETTLED" && break
  sleep 10
done
```
Expected: root/platform/backend 순차 생성. platform이 DB·Redis·ingress·RBAC 배포 → backend PreSync Job(db-migrate)이 postgres 대기 후 `migrate deploy`(init 적용)+`seed` 실행 → 앱 3종 배포.

- [ ] **Step 7: 배포 검증**

```bash
kubectl get applications -n argocd    # root/platform/backend = Synced + Healthy
kubectl get pods -n default           # postgres/mongo/redis/lobby/matchmaking/room 전부 Running (AGE 방금)
kubectl logs job/db-migrate -n default | tail -15   # migrate 적용 + "✅ Seed complete!"
# ingress 라우팅 확인 (NodePort 31000)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:31000/lobby/  || echo "lobby route check"
# DB에 마이그레이션/seed 반영 확인
PGPOD=$(kubectl get pod -n default -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default "$PGPOD" -- psql -U postgres -d postgres -c "SELECT migration_name FROM _prisma_migrations;" 2>&1 | head
kubectl exec -n default "$PGPOD" -- psql -U postgres -d postgres -c "SELECT count(*) FROM \"Character\";" 2>&1 | head
```
Expected: 3 Application Synced+Healthy, 6개 앱/DB 파드 Running, db-migrate Job Complete(init 적용 + seed), `_prisma_migrations`에 init 기록, Character 테이블에 seed 행 존재. (앱은 구 이미지라 완전 동작까진 Phase 2 이미지 필요 — 여기선 파드 Running + DB 마이그레이션까지가 성공 기준.)

- [ ] **Step 8: README + Commit + push**

`k8s/argocd/README.md`: app-of-apps 구조, sync-wave 순서, 접속법, "배포 = 커밋+push → 자동 sync", 롤백 = 커밋 revert, ingress-nginx는 부트스트랩(ArgoCD 밖).
```bash
git add -A && git commit -m "docs(argocd): app-of-apps 구조 및 운영 가이드"
git push origin main
```

---

### Task 7: infrastructure README 갱신 + 최종 검증

**Files:**
- Modify: `infrastructure/README.md`

- [ ] **Step 1: README 재작성**

기존 "배포 순서(수동 kubectl apply)" 섹션을 ArgoCD 기반으로 교체. 새 트리(`k8s/platform`, `k8s/apps/backend`, `k8s/argocd`, `k8s/local-k8s`(ingress-nginx만)), ArgoCD 접속·배포·롤백 워크플로, 기존 트러블슈팅/개념 요약 유지.

- [ ] **Step 2: 전체 정합성 검증**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
kubectl kustomize k8s/platform >/dev/null && echo "platform OK"
kubectl kustomize k8s/apps/backend >/dev/null && echo "backend OK"
kubectl get applications -n argocd
kubectl get pods -n default
```
Expected: 렌더 OK, 3 Application Synced+Healthy, 파드 전부 Running.

- [ ] **Step 3: Commit + push**

```bash
git add -A && git commit -m "docs: infrastructure README를 ArgoCD/Kustomize 기반으로 갱신"
git push origin main
```

---

## 완료 기준 (Phase 1 검증)

1. `k8s/platform`, `k8s/apps/backend`가 Kustomize로 렌더됨
2. 기존 leftover 리소스 teardown 완료 (default ns 클린)
3. ArgoCD 설치됨, root/platform/backend가 Synced+Healthy로 **빈 클러스터에 전체 스택 새로 배포**
4. sync-wave + initContainer로 DB→앱 순서 보장, db-migrate PreSync Job이 빈 DB에 init 적용 + seed
5. infrastructure README가 ArgoCD 워크플로 반영

## 의도적으로 Phase 1에서 제외

- sha 이미지 태깅 + `kustomize edit set image` 자동화 → Phase 2 (CI). 앱은 기존 `:latest`(구 코드)로 뜸.
- 모노레포 앱 이미지 빌드·푸시(현재 코드 반영) → Phase 2 CI. Phase 1은 db-migrate 이미지만 수동 푸시.
- ingress에 `argocd.localhost` 호스트 → 지금은 port-forward.
- 원본 서버 레포 k8s/ 삭제 + 레포 archive → Phase 2.
- 게임서버 config Application → Phase 3.
