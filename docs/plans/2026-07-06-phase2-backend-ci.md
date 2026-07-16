# Phase 2: 백엔드 CI 워크플로 (GitHub Actions) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** lop-backend에 GitHub Actions 워크플로를 만들어, 버튼(workflow_dispatch)을 누르면 변경 앱을 빌드·테스트 → 멀티아치 이미지를 `re5nardo/<app>-server:<sha>`로 푸시 → infrastructure 레포의 Kustomize 이미지 태그를 그 sha로 bump·commit·push → ArgoCD가 자동 배포하게 한다. 동시에 Phase 1에서 남은 "lobby/matchmaking이 구 이미지로 도는" 드리프트 트랩을 해소한다.

**Architecture:** CI(빌드·이미지 푸시·태그 bump) = GitHub Actions(호스티드 러너, 클라우드). CD(배포) = ArgoCD(Phase 1에서 구축). 둘의 접점은 infrastructure 레포 커밋. 워크플로는 클러스터에 접근하지 않는다 — 태그 bump만 하면 ArgoCD가 나머지를 한다.

**Tech Stack:** GitHub Actions (ubuntu-latest 호스티드), pnpm+Turborepo, docker buildx(멀티아치 amd64+arm64), kustomize CLI, Docker Hub(re5nardo), ArgoCD(기구축).

**설계 문서:** `infrastructure/docs/specs/2026-07-05-deployment-system-design.md`
**선행:** Phase 0(lop-backend 모노레포), Phase 1(infrastructure+ArgoCD) 완료.

---

## Global Constraints

**결정 사항 (2026-07-06, 사용자 확정):**
- 러너: **GitHub 호스티드**(ubuntu-latest). 셀프호스트는 Unity가 필요한 Phase 3에서 도입. 백엔드 빌드는 클러스터 접근이 없어 클라우드 러너로 충분.
- 이미지: **멀티아치 amd64+arm64** (buildx). 기존 배포 스크립트와 동일 방식. 로컬(arm64)·미래 클라우드(amd64) 모두 커버.
- 이미지 태그: **lop-backend git short sha**. `:latest` 참조 폐지 — infra kustomization의 `newTag`를 sha로 관리.

**현재 사실 (조사 확정):**
- lop-backend: github.com/Baeinsoo/lop-backend(private, main). `.github/workflows/` 없음. apps/{lobby,matchmaking,room}-server + packages/database, 각 Dockerfile은 루트 컨텍스트 `pnpm deploy` 패턴. db-migrate Dockerfile도 있음.
- infrastructure: github.com/Baeinsoo/infrastructure(PUBLIC, main). `k8s/apps/backend/<app>-server/kustomization.yaml`에 `images: [{name: re5nardo/<app>-server, newTag: latest}]` 존재(태그 bump 지점). db-migrate도 `k8s/apps/backend/db-migrate/kustomization.yaml`에 동일 패턴.
- ArgoCD backend Application이 `k8s/apps/backend`를 automated(prune+selfHeal) sync 중.
- Docker Hub: 앱 이미지 `re5nardo/{lobby,matchmaking,room}-server:latest` 존재하나 **lobby/matchmaking은 구 pre-monorepo 코드**(Phase 1에서 미검증), room은 arm64-only 모노레포 이미지, db-migrate는 수정된 모노레포 이미지.
- gh 계정 2개: `Baeinsoo`(scopes: repo — **workflow 없음**), `insoobae-83`(repo+workflow). `.github/workflows/*` 파일을 git push하려면 push에 쓰이는 토큰에 **workflow scope 필요** → 스냅 주의(아래 Task 2).

**불변 규칙:**
1. 워크플로는 클러스터를 건드리지 않는다(kubectl 없음). 배포는 오직 태그 bump→ArgoCD.
2. 이미지 태그는 sha. 첫 실행 후 infra 매니페스트는 더 이상 `:latest`에 의존하지 않는다.
3. **드리프트 트랩 우선 해소**: 자동 CI를 상시화하기 전, 3개 앱을 모노레포 코드로 재빌드해 실제로 배포·기동됨을 검증(Task 3). 모노레포 앱 이미지는 아직 실클러스터에서 돈 적 없음 → 런타임 버그 가능(Phase 1 seed 버그 전례). 크래시하면 디버깅.
4. 시크릿(Docker Hub 토큰, infra PAT)은 GitHub 레포 Secrets에만 저장. 코드/로그에 노출 금지.
5. 파괴적이지 않음: 이 Phase는 새 워크플로 추가 + 이미지 재빌드 + 태그 bump. ArgoCD가 rolling update로 앱을 교체(무중단 지향, 로컬이라 재시작 무방).

**검증:** 워크플로 실행 결과(Actions 콘솔), `kubectl get application backend -n argocd`(Synced+Healthy), `kubectl get pods -n default`(6 Running), 각 앱이 새 sha 이미지로 교체됐는지.

---

### Task 1: GitHub Secrets 설정 (사용자 제공)

워크플로가 Docker Hub 푸시 + infra 레포 태그 bump push를 하려면 시크릿 2~3개가 필요하다. 이 태스크는 대부분 **사용자 액션**이며, 값 확인만 자동화한다.

**Files:** 없음 (GitHub 설정)

**Interfaces:**
- Produces: lop-backend 레포에 등록된 `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `INFRA_REPO_TOKEN` 시크릿. Task 2 워크플로가 참조.

- [ ] **Step 1: 필요한 시크릿 안내 (사용자에게 요청)**

사용자가 아래를 GitHub에 등록해야 한다 (실행자는 안내 + gh로 등록 시도):
1. **Docker Hub 액세스 토큰**: Docker Hub → Account Settings → Personal access tokens → Read/Write 토큰 발급.
2. **infra 레포 PAT**: GitHub Settings → Developer settings → Personal access tokens. `Baeinsoo/infrastructure`에 **Contents: write** 권한(classic이면 `repo` scope). 워크플로가 infra 레포에 태그 bump를 push하는 데 사용(기본 GITHUB_TOKEN은 lop-backend에만 유효하므로 별도 필요).

- [ ] **Step 2: 시크릿 등록 (gh CLI)**

값을 받은 뒤 (사용자가 `!` 로 실행하거나 값을 제공하면 실행자가 등록):
```bash
gh secret set DOCKERHUB_USERNAME --repo Baeinsoo/lop-backend --body "re5nardo"
gh secret set DOCKERHUB_TOKEN    --repo Baeinsoo/lop-backend --body "<dockerhub-token>"
gh secret set INFRA_REPO_TOKEN   --repo Baeinsoo/lop-backend --body "<infra-PAT>"
```
(민감값은 로그에 남지 않게. gh secret set은 값을 암호화 저장한다.)

- [ ] **Step 3: 등록 확인**

```bash
gh secret list --repo Baeinsoo/lop-backend
```
Expected: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `INFRA_REPO_TOKEN` 3개 존재 (값은 안 보임).
등록 불가(사용자 미제공)면 BLOCKED로 보고하고 사용자 액션 대기.

---

### Task 2: 백엔드 배포 워크플로 작성

버튼 하나로 도는 `workflow_dispatch` 워크플로. 대상 앱 선택 → 빌드·테스트 → 멀티아치 이미지 push → infra 태그 bump.

**Files:**
- Create: `lop-backend/.github/workflows/backend-deploy.yml`

**Interfaces:**
- Consumes: Task 1 시크릿, lop-backend Dockerfile들, infra 레포 kustomization.
- Produces: 실행 가능한 워크플로. Task 3·4가 실행.

- [ ] **Step 1: 워크플로 작성**

`lop-backend/.github/workflows/backend-deploy.yml`:
```yaml
name: backend-deploy
on:
  workflow_dispatch:
    inputs:
      app:
        description: "배포 대상"
        required: true
        default: all
        type: choice
        options: [all, lobby-server, matchmaking-server, room-server, db-migrate]

concurrency:
  group: backend-deploy
  cancel-in-progress: false

jobs:
  build-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - app: lobby-server
            image: re5nardo/lobby-server
            dockerfile: apps/lobby-server/Dockerfile
          - app: matchmaking-server
            image: re5nardo/matchmaking-server
            dockerfile: apps/matchmaking-server/Dockerfile
          - app: room-server
            image: re5nardo/room-server
            dockerfile: apps/room-server/Dockerfile
          - app: db-migrate
            image: re5nardo/lop-db-migrate
            dockerfile: packages/database/Dockerfile
    steps:
      - name: 대상 필터 (선택 앱만 진행)
        id: filter
        run: |
          if [ "${{ inputs.app }}" = "all" ] || [ "${{ inputs.app }}" = "${{ matrix.app }}" ]; then
            echo "run=true" >> "$GITHUB_OUTPUT"
          else
            echo "run=false" >> "$GITHUB_OUTPUT"
          fi

      - uses: actions/checkout@v4
        if: steps.filter.outputs.run == 'true'

      - name: sha 태그 산출
        if: steps.filter.outputs.run == 'true'
        id: tag
        run: echo "sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      - uses: pnpm/action-setup@v4
        if: steps.filter.outputs.run == 'true'
        with: { version: 10.11.0 }
      - uses: actions/setup-node@v4
        if: steps.filter.outputs.run == 'true'
        with: { node-version: 22, cache: pnpm }

      - name: 빌드·테스트 (turbo, 해당 앱)
        if: steps.filter.outputs.run == 'true' && matrix.app != 'db-migrate'
        run: |
          pnpm install --frozen-lockfile
          pnpm --filter ${{ matrix.app }} run build

      - uses: docker/setup-qemu-action@v3
        if: steps.filter.outputs.run == 'true'
      - uses: docker/setup-buildx-action@v3
        if: steps.filter.outputs.run == 'true'
      - uses: docker/login-action@v3
        if: steps.filter.outputs.run == 'true'
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: 멀티아치 빌드·푸시
        if: steps.filter.outputs.run == 'true'
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ matrix.dockerfile }}
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ${{ matrix.image }}:${{ steps.tag.outputs.sha }}
          provenance: false

      - name: 산출 태그 기록 (아티팩트)
        if: steps.filter.outputs.run == 'true'
        run: echo "${{ matrix.app }}=${{ matrix.image }}:${{ steps.tag.outputs.sha }}" >> tags-${{ matrix.app }}.txt
      - uses: actions/upload-artifact@v4
        if: steps.filter.outputs.run == 'true'
        with:
          name: tag-${{ matrix.app }}
          path: tags-${{ matrix.app }}.txt

  bump-tags:
    needs: build-push
    runs-on: ubuntu-latest
    steps:
      - name: infra 레포 체크아웃
        uses: actions/checkout@v4
        with:
          repository: Baeinsoo/infrastructure
          token: ${{ secrets.INFRA_REPO_TOKEN }}
          ref: main
      - uses: actions/download-artifact@v4
        with: { path: /tmp/tags }
      - name: kustomize 설치
        run: |
          curl -sL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/
      - name: 이미지 태그 bump
        run: |
          set -e
          shopt -s nullglob
          declare -A DIR=( [lobby-server]=k8s/apps/backend/lobby-server [matchmaking-server]=k8s/apps/backend/matchmaking-server [room-server]=k8s/apps/backend/room-server [db-migrate]=k8s/apps/backend/db-migrate )
          declare -A IMG=( [lobby-server]=re5nardo/lobby-server [matchmaking-server]=re5nardo/matchmaking-server [room-server]=re5nardo/room-server [db-migrate]=re5nardo/lop-db-migrate )
          for f in /tmp/tags/*/tags-*.txt; do
            line=$(cat "$f"); app=${line%%=*}; ref=${line#*=}; tag=${ref##*:}
            ( cd "${DIR[$app]}" && kustomize edit set image "${IMG[$app]}=${IMG[$app]}:${tag}" )
            echo "bumped $app -> $tag"
          done
      - name: commit + push (있을 때만)
        run: |
          git config user.name "lop-ci"
          git config user.email "ci@lop.local"
          if ! git diff --quiet; then
            git add -A
            git commit -m "ci(deploy): bump backend image tags [skip ci]"
            git push origin main
          else
            echo "변경 없음 (태그 동일)"
          fi
```

설명: matrix로 4개 이미지, `inputs.app` 필터로 선택 대상만 빌드. `build-push` job이 멀티아치 이미지를 sha로 push하고 태그를 아티팩트로 전달. `bump-tags` job이 infra 레포를 PAT로 체크아웃해 `kustomize edit set image`로 태그를 갱신하고 commit·push. `[skip ci]`로 무한루프 방지(해당 없지만 관례). push 후 ArgoCD가 자동 sync.

- [ ] **Step 2: 로컬 YAML 문법 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/backend-deploy.yml')); print('YAML OK')"
```
Expected: YAML OK.

- [ ] **Step 3: Commit + push (workflow scope 주의)**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
git add .github/workflows/backend-deploy.yml
git commit -m "ci: 백엔드 배포 워크플로 (workflow_dispatch, 멀티아치, infra 태그 bump)"
git push origin main
```
**스냅 주의**: `.github/workflows/*` push는 push 토큰에 **workflow scope**가 필요하다. 활성 계정 `Baeinsoo`는 workflow scope가 없어 push가 거부될 수 있다(`refusing to allow ... without workflow scope`). 대응:
- `insoobae-83` 계정(workflow scope 보유)으로 push하거나,
- `Baeinsoo` 토큰에 workflow scope 추가(`gh auth refresh -h github.com -s workflow`),
- 또는 workflow scope PAT로 원격 URL 임시 설정.
거부되면 사용자에게 `gh auth refresh -s workflow` 실행을 요청.

---

### Task 3: 첫 실행 — 3종 재빌드·검증 (드리프트 트랩 해소)

워크플로를 `all`로 실행해 모노레포 코드로 4개 이미지를 sha 빌드·푸시하고, ArgoCD가 새 이미지로 배포·기동함을 검증한다. **여기서 모노레포 앱 이미지가 실클러스터에서 처음 검증된다.**

**Files:** 없음 (실행·검증)

- [ ] **Step 1: 워크플로 실행 (all)**

```bash
gh workflow run backend-deploy.yml --repo Baeinsoo/lop-backend -f app=all
sleep 5; gh run list --repo Baeinsoo/lop-backend --workflow backend-deploy.yml --limit 1
```

- [ ] **Step 2: 실행 완료 대기 + 결과**

```bash
RID=$(gh run list --repo Baeinsoo/lop-backend --workflow backend-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RID" --repo Baeinsoo/lop-backend --exit-status || echo "워크플로 실패 — 로그 확인: gh run view $RID --log-failed"
```
Expected: build-push(4 matrix) + bump-tags 성공. 실패 시 `gh run view $RID --log-failed`로 원인 파악(빌드 에러/푸시 권한/kustomize).

- [ ] **Step 3: infra 태그 bump 확인**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure && git pull origin main --quiet
grep -r "newTag" k8s/apps/backend/*/kustomization.yaml
```
Expected: 각 kustomization의 newTag가 sha로 바뀜(더 이상 `latest` 아님).

- [ ] **Step 4: ArgoCD 배포 검증 (모노레포 이미지 실기동)**

```bash
for i in $(seq 1 30); do
  BE=$(kubectl get application backend -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  PODS=$(kubectl get pods -n default --no-headers 2>/dev/null | grep -vE 'Completed' | awk '{print $1"="$3}' | tr '\n' ' ')
  echo "[$i] backend=$BE | $PODS"
  echo "$BE" | grep -q "Synced/Healthy" && echo ">>> SETTLED" && break
  sleep 10
done
kubectl get pods -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' | grep server
```
Expected: backend Synced+Healthy, 앱 파드가 **새 sha 이미지**로 Running. `curl -s -o /dev/null -w "%{http_code}" http://localhost:31000/lobby/` = 200.
**모노레포 앱 이미지가 크래시하면(CrashLoopBackOff)**: `kubectl logs`로 원인 파악 후 lop-backend에서 수정(Phase 1 seed 버그처럼) → 재실행. 이 태스크의 핵심 가치가 바로 이 검증이다.

- [ ] **Step 5: db-migrate 재확인**

```bash
kubectl get job db-migrate -n default -o jsonpath='{.status.succeeded} succeeded'; echo
kubectl logs job/db-migrate -n default 2>&1 | tail -3
```
Expected: Job 성공, seed 정상 (멱등).

---

### Task 4: 엔드투엔드 버튼 흐름 검증 (단일 앱)

"코드 변경 → 버튼 → 배포"가 실제로 도는지 단일 앱으로 확인한다.

**Files:** lop-backend에 사소한 검증용 변경 1건(예: 주석/버전 로그)

- [ ] **Step 1: lobby-server에 사소한 변경 + push**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
# 예: 부팅 로그에 빌드 마커 추가 또는 주석 — 실제로 이미지에 반영되는 변경
# (구현자가 apps/lobby-server/src/main.ts 등에 무해한 로그/주석 1줄 추가)
git add -A && git commit -m "chore(lobby): 배포 파이프라인 검증용 변경" && git push origin main
```

- [ ] **Step 2: lobby만 배포 실행**

```bash
gh workflow run backend-deploy.yml --repo Baeinsoo/lop-backend -f app=lobby-server
RID=$(sleep 5; gh run list --repo Baeinsoo/lop-backend --workflow backend-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RID" --repo Baeinsoo/lop-backend --exit-status
```

- [ ] **Step 3: lobby만 새 sha로 교체됐는지 확인 (matchmaking/room은 그대로)**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure && git pull origin main --quiet
grep newTag k8s/apps/backend/lobby-server/kustomization.yaml   # 새 sha
# ArgoCD sync 후
sleep 30; kubectl get pods -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' | grep -E 'lobby|matchmaking|room'
```
Expected: lobby-server 파드만 새 sha 이미지로 교체(AGE 방금), matchmaking/room은 이전 sha 유지. backend Synced+Healthy.

- [ ] **Step 4: 롤백 확인 (선택)**

infra 레포에서 직전 bump 커밋을 revert→push하면 ArgoCD가 이전 sha로 롤백함을 확인(문서화). 실제 실행은 선택.

---

### Task 5: 정리 + 원본 레포 archive + 문서

Phase 1/2에서 쌓인 이월 항목 중 값싼 것 정리 + 원본 서버 레포 archive + 문서 갱신.

**Files:**
- Modify: `lop-backend/packages/database/package.json`(ts-node 제거), infra `README.md`/이월 문서
- 원격: 원본 4개 레포 archive

- [ ] **Step 1: 미사용 ts-node 제거 (Phase 1 리뷰 지적)**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
# packages/database/package.json devDependencies에서 ts-node 제거 (seed는 이제 컴파일 실행, ts-node 미사용)
# 편집 후:
pnpm install
pnpm --filter @lop/database build   # 여전히 성공해야 함
git add -A && git commit -m "chore(database): 미사용 ts-node devDependency 제거" && git push origin main
```

- [ ] **Step 2: 원본 서버 레포 archive (모노레포로 대체됨)**

CI가 모노레포 기준으로 정상 동작함을 Task 3·4에서 확인했으므로, 원본 4개 레포를 archive(삭제 아님, 읽기전용):
```bash
for r in LeagueOfPhysical-LobbyServer LeagueOfPhysical-MatchmakingServer LeagueOfPhysical-RoomServer; do
  gh repo archive re5nardo/$r --yes 2>&1 || echo "archive 실패/권한: $r"
done
gh repo archive Baeinsoo/db-admin --yes 2>&1 || echo "archive 실패/권한: db-admin"
```
(권한/소유 문제로 실패하면 사용자에게 위임. 로컬 워킹카피는 그대로 두되 README에 "archived, lop-backend로 대체" 명시.)

- [ ] **Step 3: 문서 갱신**

- infra `README.md`: "배포 = infra 커밋+push" 외에 "코드 변경 → lop-backend Actions 버튼 → 자동 이미지 빌드·태그 bump → ArgoCD" 흐름 추가. `:latest` → sha 태깅 전환 반영.
- `k8s/argocd/README.md`의 Phase 2 이월 항목 중 완료분(이미지 sha 태깅, lobby/matchmaking 재빌드, ts-node 제거) 정리.

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git add -A && git commit -m "docs: Phase 2(백엔드 CI) 반영 — sha 태깅·버튼 배포 흐름" && git push origin main
```

- [ ] **Step 4: 최종 검증**

```bash
kubectl get application backend -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'; echo
kubectl get pods -n default --no-headers | grep server
gh workflow list --repo Baeinsoo/lop-backend
```
Expected: backend Synced+Healthy, 앱 3종 새 sha 이미지로 Running, 워크플로 등록됨.

---

## 완료 기준 (Phase 2 검증)

1. lop-backend에 `backend-deploy.yml` 워크플로 존재, 버튼으로 실행됨
2. 첫 실행이 4개 이미지를 멀티아치 sha로 빌드·푸시, infra 태그 bump, ArgoCD가 **모노레포 이미지**로 배포 → 6 파드 Running(드리프트 트랩 해소)
3. 단일 앱 변경→버튼→해당 앱만 새 sha로 배포되는 엔드투엔드 흐름 확인
4. infra 매니페스트가 `:latest` 대신 sha 참조
5. 원본 서버 레포 archive, ts-node 제거, 문서 갱신

## 의도적으로 Phase 2에서 제외

- push 자동 트리거(`on: push`) — 지금은 버튼(workflow_dispatch)만. 한 줄 추가로 확장 가능.
- 셀프호스트 러너 → Phase 3(Unity 게임서버)에서 도입.
- Unity 게임서버/클라이언트/어드레서블 파이프라인 → Phase 3·4.
- db-migrate 이미지 슬림화(멀티스테이지), 앱 resource limits/probes/HA → 별도 hardening.
- 테스트 스위트 — 현재 프로젝트에 테스트 없음. `turbo run test`는 앱에 test 스크립트가 생기면 자동 편입.
