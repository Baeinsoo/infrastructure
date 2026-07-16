# Phase 3: Unity 게임서버 빌드·배포 파이프라인 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unity 게임서버(LeagueOfPhysical-Server)를 버튼 하나로 batchmode 빌드 → 도커 이미지(`re5nardo/game-server:<sha>`) 푸시 → room-server가 참조하는 이미지 태그를 ConfigMap으로 갱신하는 파이프라인을 구축한다. 이로써 room-server의 하드코딩된 `game-server:latest` 의존을 제거하고, 게임서버도 sha 태깅·GitOps 배포 체계에 편입한다.

**Architecture:** Unity 빌드는 **셀프호스트 러너(맥, arm64, Unity 라이선스 활성화)**에서 batchmode 실행. 산출 Linux 서버 바이너리를 도커 이미지로 패키징해 sha로 푸시. 이미지 태그는 infra의 `game-server-config` ConfigMap(`GAME_SERVER_IMAGE`)에 기록되고 ArgoCD가 관리. room-server는 매치 pod 생성 시 이 env를 읽는다.

**Tech Stack:** Unity 6000.3.16f1 (Dedicated Server, IL2CPP, StandaloneLinux64), GitHub Actions(셀프호스트 러너), docker, ArgoCD/Kustomize(기구축), Node/TS(room-server).

**설계 문서:** `infrastructure/docs/specs/2026-07-05-deployment-system-design.md`
**선행:** Phase 0(모노레포), Phase 1(ArgoCD), Phase 2(백엔드 CI) 완료.

---

## Global Constraints

**결정 사항 (2026-07-06, 사용자 확정):**
- 러너: **셀프호스트(맥)**. 라이선스 활성화됨 + arm64. GitHub 클라우드(GameCI)는 라이선스·arch 문제로 로컬엔 부적합(클라우드 운영 시 재고).
- 검증 범위: **이미지 + 설정 배선까지**. 실제 매치 생성으로 game-server pod를 띄우는 E2E는 범위 밖(별도).
- 게임서버 이미지 아키텍처: **amd64** (표준 StandaloneLinux64 Server IL2CPP, 클라우드 대비). 로컬 arm64 클러스터에서 pod로 실제 실행하려면 에뮬레이션 또는 arm64 빌드가 필요 — 이는 이번 범위 밖(pod 기동 검증을 안 하므로 무방).

**현재 사실 (조사 확정):**
- Unity 프로젝트: `github.com/Baeinsoo/LeagueOfPhysical-Server`(main, **archive 안 됨**), Unity 6000.3.16f1. `Build/`·`Library/` gitignore. Dedicated Server 서브타겟+IL2CPP 설정됨.
- **batchmode 빌드 스크립트 없음** → 신규 작성 필요. 기존 에디터 스크립트는 `Assets/Scripts/Editor/EnvironmentSwitcher.cs`(빌드와 무관)뿐. `Assets/Editor/` 없음.
- Dockerfile `GameServer/Dockerfile`: `ubuntu:20.04`, `COPY Build/ /app/`, `CMD ["/app/lop-server.x86_64","-batchmode","-nographics"]`, `EXPOSE 7777`.
- **컨텍스트 경로 버그**: `game-server-build-push.sh`가 `cd ../`로 컨텍스트를 `GameServer/`로 잡는데 Dockerfile은 `COPY Build/` → `GameServer/Build/`를 기대. 하지만 Unity 산출물은 프로젝트 루트 `Build/`. 이 불일치를 해소해야 함.
- room-server(lop-backend `apps/room-server/src/services/room.service.ts:147`): `image: 're5nardo/game-server:latest'` **하드코딩**, `imagePullPolicy: Always`, 포트 `7777/UDP`, env `ROOM_ID`+`PORT=7777`, Service `NodePort`. ConfigMap/env 간접참조 없음.
- 로컬 Unity에 `linux64_server_nondevelopment_il2cpp` variation 존재 → amd64 Linux Dedicated Server IL2CPP 빌드 가능. 러너 미등록(Phase 2에서 확인).
- 셀프호스트 러너는 맥의 **ambient 자격증명** 사용: docker는 이미 로그인(re5nardo), git은 Baeinsoo(infra write 권한). → 게임서버 워크플로엔 별도 시크릿 불필요.

**불변 규칙:**
1. Unity 산출물(수백 MB~1.4GB)은 git에 커밋하지 않는다(이미 gitignore). CI가 매번 fresh 빌드.
2. 이미지 태그는 sha. room-server는 `:latest`를 하드코딩하지 않고 `GAME_SERVER_IMAGE` env(ConfigMap)에서 읽는다(하위호환 fallback 허용).
3. 게임서버 워크플로는 셀프호스트 러너에서만 실행(`runs-on: self-hosted`). Unity 빌드는 맥 로컬 Unity·라이선스에 의존.
4. `game-server-config` ConfigMap은 ArgoCD(backend Application)가 관리. CI는 이 값을 bump·push하고 ArgoCD가 sync.
5. room-server는 ConfigMap 변경을 pod 재시작 시 반영한다(envFrom/env는 런타임 자동 리로드 안 됨). Phase 3 검증은 "배선"이므로 재시작 반영까지 확인하고, 매치별 실시간 반영 최적화는 범위 밖.

**검증:** 워크플로 실행(Actions 콘솔), `re5nardo/game-server:<sha>` 레지스트리 존재, infra `game-server-config` ConfigMap의 `GAME_SERVER_IMAGE`가 sha, room-server 배포 env가 그 ConfigMap 참조, ArgoCD Synced.

---

### Task 1: 셀프호스트 러너 설치 (맥)

LeagueOfPhysical-Server 레포에 셀프호스트 러너를 등록해 Unity batchmode 빌드를 맥에서 실행할 수 있게 한다.

**Files:** 없음 (러너 설치 — 맥 로컬 + GitHub 등록)

**Interfaces:**
- Produces: `self-hosted` 라벨 러너(온라인). Task 5 워크플로가 `runs-on: self-hosted`로 사용.

- [ ] **Step 1: 등록 토큰 발급 + 러너 다운로드**

```bash
# 등록 토큰 (Baeinsoo가 레포 admin이라 발급 가능)
TOKEN=$(gh api -X POST repos/Baeinsoo/LeagueOfPhysical-Server/actions/runners/registration-token --jq .token)
echo "token 발급: ${TOKEN:0:8}..."
# 러너 디렉토리 (맥, 프로젝트 밖 — 예: ~/actions-runner-lop)
mkdir -p ~/actions-runner-lop && cd ~/actions-runner-lop
# 최신 macOS arm64 러너 (버전은 https://github.com/actions/runner/releases 최신으로)
RUNNER_VER=2.320.0
curl -sLo runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-osx-arm64-${RUNNER_VER}.tar.gz"
tar xzf runner.tar.gz
```
등록 토큰 발급이 권한 오류면(admin 아님) 사용자에게 GitHub UI(Settings → Actions → Runners → New self-hosted runner)로 위임.

- [ ] **Step 2: 러너 구성 (비대화형)**

```bash
cd ~/actions-runner-lop
./config.sh --unattended \
  --url https://github.com/Baeinsoo/LeagueOfPhysical-Server \
  --token "$TOKEN" \
  --name lop-mac-runner \
  --labels self-hosted,macos,unity \
  --work _work
```
Expected: "Runner successfully added" + "Connected to GitHub".

- [ ] **Step 3: launchd 서비스로 상주 실행**

```bash
cd ~/actions-runner-lop
./svc.sh install
./svc.sh start
./svc.sh status
```
Expected: 서비스 실행 중. (서비스는 로그인 사용자로 돌아 맥의 Unity 라이선스·docker 로그인·git 인증을 그대로 사용.)
서비스 대신 포그라운드 테스트만 원하면 `./run.sh`(터미널 점유). 상주엔 svc 권장.

- [ ] **Step 4: 러너 온라인 확인**

```bash
gh api repos/Baeinsoo/LeagueOfPhysical-Server/actions/runners --jq '.runners[] | .name + " => " + .status'
```
Expected: `lop-mac-runner => online`.

---

### Task 2: Unity batchmode 빌드 스크립트 (BuildScript.cs)

CI가 호출할 `-executeMethod` 대상을 작성한다. Linux(amd64) Dedicated Server IL2CPP 빌드를 Dockerfile이 기대하는 경로로 산출.

**Files:**
- Create: `LeagueOfPhysical-Server/Assets/Scripts/Editor/BuildScript.cs`

**Interfaces:**
- Produces: `BuildScript.BuildLinuxServer` static 메서드. Task 5 워크플로가 `-executeMethod BuildScript.BuildLinuxServer` 로 호출. 산출물은 `GameServer/Build/`(Dockerfile COPY 대상).

- [ ] **Step 1: BuildScript.cs 작성**

`Assets/Scripts/Editor/BuildScript.cs`:
```csharp
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEngine;

public static class BuildScript
{
    // CI: Unity -batchmode -quit -nographics -projectPath . -executeMethod BuildScript.BuildLinuxServer -logFile -
    public static void BuildLinuxServer()
    {
        // 산출 경로: Dockerfile(GameServer/Dockerfile)이 `COPY Build/`로 기대 → GameServer/Build/lop-server.x86_64
        var outputDir = "GameServer/Build";
        var exe = outputDir + "/lop-server.x86_64";

        var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();

        // Dedicated Server 서브타겟 + IL2CPP (프로젝트 설정과 일치)
        EditorUserBuildSettings.standaloneBuildSubtarget = StandaloneBuildSubtarget.Server;
        var named = NamedBuildTarget.Server;
        PlayerSettings.SetScriptingBackend(named, ScriptingImplementation.IL2CPP);

        var options = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = exe,
            target = BuildTarget.StandaloneLinux64,
            subtarget = (int)StandaloneBuildSubtarget.Server,
            options = BuildOptions.None,
        };

        var report = BuildPipeline.BuildPlayer(options);
        var summary = report.summary;
        if (summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded)
        {
            Debug.LogError($"Build FAILED: {summary.result}, errors={summary.totalErrors}");
            EditorApplication.Exit(1);
        }
        Debug.Log($"Build OK: {summary.outputPath}, size={summary.totalSize} bytes");
        EditorApplication.Exit(0);
    }
}
```

- [ ] **Step 2: 로컬 batchmode 빌드로 검증 (Dockerfile 경로 확인)**

셀프호스트 러너가 돌기 전, 맥에서 직접 한 번 돌려 산출 경로·성공을 확인:
```bash
UNITY=/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
"$UNITY" -batchmode -quit -nographics -projectPath . -executeMethod BuildScript.BuildLinuxServer -logFile - 2>&1 | tail -30
ls -la GameServer/Build/ && test -f GameServer/Build/lop-server.x86_64 && echo "BUILD OUTPUT OK"
```
Expected: 빌드 성공, `GameServer/Build/lop-server.x86_64` + `GameServer/Build/lop-server_Data/` + `.so` 파일 생성. (IL2CPP라 수십 분 걸릴 수 있음.)
빌드 실패 시 로그의 컴파일 에러 확인. `NamedBuildTarget.Server`/`subtarget` API가 이 Unity 버전에서 다르면 그에 맞게 조정(핵심은 StandaloneLinux64 + Server 서브타겟 + IL2CPP).

- [ ] **Step 3: Commit (Build 산출물은 gitignore라 스크립트만)**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
git add Assets/Scripts/Editor/BuildScript.cs Assets/Scripts/Editor/BuildScript.cs.meta 2>/dev/null || git add Assets/Scripts/Editor/BuildScript.cs
git commit -m "feat(build): CI용 Linux Dedicated Server batchmode 빌드 스크립트"
git push origin main
```
(`.meta`가 없으면 Unity가 생성 후 다시 커밋. GameServer/Build/는 gitignore되어 커밋 안 됨.)

---

### Task 3: Dockerfile 컨텍스트 정합 + room-server ConfigMap 참조 (코드)

Dockerfile/빌드 경로 불일치를 해소하고, room-server가 이미지 태그를 env에서 읽도록 바꾼다.

**Files:**
- Modify: `LeagueOfPhysical-Server/GameServer/Dockerfile` (또는 빌드 산출 경로 정합 확인)
- Modify: `lop-backend/apps/room-server/src/services/room.service.ts` (하드코딩 → env)

**Interfaces:**
- Consumes: Task 2의 `GameServer/Build/` 산출물
- Produces: 컨텍스트 `GameServer/`에서 빌드 가능한 이미지. room-server가 `GAME_SERVER_IMAGE` env 사용.

- [ ] **Step 1: Dockerfile 경로 정합 확인**

Task 2가 `GameServer/Build/`로 산출하므로 Dockerfile `COPY Build/ /app/`(컨텍스트 `GameServer/`)와 일치한다. 확인만:
```bash
cat /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server/GameServer/Dockerfile | grep -E "COPY|WORKDIR|CMD"
```
Expected: `COPY Build/ /app/`. Task 2 산출 경로와 정합. (불일치가 있으면 Task 2 outputDir 또는 Dockerfile COPY를 맞춘다.)
참고: `Build/lop-server_BackUpThisFolder_ButDontShipItWithYourGame/`(디버그 심볼)는 이미지에 넣지 않도록 `.dockerignore`(GameServer/.dockerignore)에 추가 권장:
```bash
printf 'Build/*_BackUpThisFolder_ButDontShipItWithYourGame/\nBuild/.DS_Store\n' > /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server/GameServer/.dockerignore
```

- [ ] **Step 2: room-server 이미지 참조를 env로**

`apps/room-server/src/services/room.service.ts:147` 근처의 하드코딩을 env 참조로 변경. 현재:
```ts
image: 're5nardo/game-server:latest',
```
변경:
```ts
image: process.env.GAME_SERVER_IMAGE || 're5nardo/game-server:latest',
```
(fallback으로 기존 리터럴 유지 — ConfigMap 미주입 시에도 동작. 다른 로직·포트·env는 불변.)

- [ ] **Step 3: room-server 빌드 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
pnpm --filter @lop/database run generate
pnpm --filter room-server run build
```
Expected: 타입체크·빌드 통과.

- [ ] **Step 4: Commit (양 레포)**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server && git add GameServer/.dockerignore && git commit -m "chore(docker): 디버그 심볼 폴더 제외" && git push origin main
cd /Users/insoobae/workspace/LOP/lop-backend && git add apps/room-server/src/services/room.service.ts && git commit -m "feat(room): game-server 이미지를 GAME_SERVER_IMAGE env에서 읽음(하드코딩 제거)" && git push origin main
```

---

### Task 4: game-server-config ConfigMap + room-server env 배선 (infra)

room-server가 참조할 `GAME_SERVER_IMAGE`를 ConfigMap으로 만들고 ArgoCD 관리에 편입, room-server 배포가 이 env를 받도록 배선한다.

**Files:**
- Create: `infrastructure/k8s/apps/backend/game-server-config/{configmap.yaml,kustomization.yaml}`
- Modify: `infrastructure/k8s/apps/backend/kustomization.yaml`(game-server-config 추가), `infrastructure/k8s/apps/backend/room-server/room-server-deployment.yaml`(env 주입)

**Interfaces:**
- Consumes: room-server 코드(GAME_SERVER_IMAGE)
- Produces: ArgoCD가 관리하는 `game-server-config` ConfigMap. Task 5 CI가 값 bump.

- [ ] **Step 1: ConfigMap 작성 (초기값 = 현재 존재하는 이미지)**

`k8s/apps/backend/game-server-config/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: game-server-config
  namespace: default
data:
  GAME_SERVER_IMAGE: re5nardo/game-server:latest   # Task 5 첫 실행 후 sha로 bump됨
```
`k8s/apps/backend/game-server-config/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
```

- [ ] **Step 2: backend kustomization에 추가**

`k8s/apps/backend/kustomization.yaml`의 resources에 `- game-server-config` 추가.

- [ ] **Step 3: room-server 배포에 env 주입**

`k8s/apps/backend/room-server/room-server-deployment.yaml`의 컨테이너 spec에 `envFrom`으로 `game-server-config`의 `room-server-config`(기존)와 함께 추가 — 기존 `envFrom`(configMapRef `room-server-config` + secretRef `postgres-secret`)에 한 줄 추가:
```yaml
          envFrom:
            - configMapRef:
                name: room-server-config
            - configMapRef:
                name: game-server-config    # GAME_SERVER_IMAGE 주입
            - secretRef:
                name: postgres-secret
```
(정확한 기존 형태는 파일 확인 후 맞춤.)

- [ ] **Step 4: 렌더 + 커밋 + push (ArgoCD 반영)**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
kubectl kustomize k8s/apps/backend | grep -A3 "game-server-config" | head
git add -A && git commit -m "feat(k8s): game-server-config ConfigMap + room-server env 배선" && git push origin main
```

- [ ] **Step 5: room-server 새 이미지 배포 (Task 3 코드 반영)**

Task 3에서 room-server 코드를 바꿨으므로 Phase 2 백엔드 워크플로로 room-server를 재배포:
```bash
gh workflow run backend-deploy.yml --repo Baeinsoo/lop-backend -f app=room-server
```
완료 후 ArgoCD sync → room-server 파드가 `GAME_SERVER_IMAGE` env를 갖는지 확인:
```bash
sleep 60; kubectl -n argocd annotate application backend argocd.argoproj.io/refresh=hard --overwrite >/dev/null
# room-server 파드 env 확인 (재시작 후)
kubectl get pod -n default -l app=room-server -o jsonpath='{.items[0].spec.containers[0].envFrom[*].configMapRef.name}'; echo
```
Expected: envFrom에 `game-server-config` 포함. (room-server가 새 sha 이미지 + env로 기동.)

---

### Task 5: 게임서버 배포 워크플로 (셀프호스트)

버튼 → Unity batchmode 빌드 → 도커 이미지 sha 푸시 → infra `game-server-config` 태그 bump.

**Files:**
- Create: `LeagueOfPhysical-Server/.github/workflows/gameserver-deploy.yml`

**Interfaces:**
- Consumes: 셀프호스트 러너(Task 1), BuildScript(Task 2), Dockerfile(Task 3), game-server-config(Task 4)
- Produces: 실행 가능한 게임서버 배포 워크플로.

- [ ] **Step 1: 워크플로 작성**

`.github/workflows/gameserver-deploy.yml`:
```yaml
name: gameserver-deploy
on:
  workflow_dispatch:

concurrency:
  group: gameserver-deploy
  cancel-in-progress: false

jobs:
  build-deploy:
    runs-on: self-hosted     # 맥 러너 (Unity 라이선스·docker·git ambient)
    steps:
      - uses: actions/checkout@v4

      - name: sha 산출
        id: tag
        run: echo "sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      - name: Unity Linux 서버 빌드 (batchmode)
        run: |
          UNITY=/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity
          "$UNITY" -batchmode -quit -nographics -projectPath . \
            -executeMethod BuildScript.BuildLinuxServer -logFile - 2>&1 | tail -40
          test -f GameServer/Build/lop-server.x86_64

      - name: 도커 이미지 빌드·푸시 (amd64, ambient docker login)
        working-directory: GameServer
        run: |
          IMG=re5nardo/game-server:${{ steps.tag.outputs.sha }}
          docker build --platform linux/amd64 -t "$IMG" .
          docker push "$IMG"
          echo "IMG=$IMG" >> "$GITHUB_ENV"

      - name: infra game-server-config 태그 bump
        run: |
          set -e
          TMP=$(mktemp -d)
          git clone --depth 1 https://github.com/Baeinsoo/infrastructure "$TMP/infra"
          cd "$TMP/infra"
          CM=k8s/apps/backend/game-server-config/configmap.yaml
          # GAME_SERVER_IMAGE 값을 새 sha로 교체
          sed -i '' -E "s|(GAME_SERVER_IMAGE: ).*|\\1re5nardo/game-server:${{ steps.tag.outputs.sha }}|" "$CM"
          if ! git diff --quiet; then
            git config user.name "lop-ci"; git config user.email "ci@lop.local"
            git commit -am "ci(gameserver): bump GAME_SERVER_IMAGE -> ${{ steps.tag.outputs.sha }} [skip ci]"
            git push origin main
          else
            echo "변경 없음"
          fi
```
설명: 셀프호스트 러너라 docker(ambient re5nardo 로그인)·git(ambient Baeinsoo, infra write)을 그대로 사용 → 시크릿 불필요. `sed -i ''`는 맥(BSD sed) 문법. Unity 빌드는 수십 분. game-server-config 값 bump 후 ArgoCD가 ConfigMap 갱신.

- [ ] **Step 2: YAML 검증 + 커밋·push (workflow scope 필요)**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
ruby -ryaml -e "YAML.load_file('.github/workflows/gameserver-deploy.yml'); puts 'YAML OK'"
git add .github/workflows/gameserver-deploy.yml
git commit -m "ci: 게임서버 배포 워크플로 (셀프호스트, Unity 빌드 → 이미지 → 태그 bump)"
git push origin main
```
(Phase 2에서 활성 계정에 workflow scope 부여됨 — 재사용.)

---

### Task 6: 첫 실행 + 배선 검증

**Files:** 없음 (실행·검증)

- [ ] **Step 1: 워크플로 실행**

```bash
gh workflow run gameserver-deploy.yml --repo Baeinsoo/LeagueOfPhysical-Server
sleep 8; RID=$(gh run list --repo Baeinsoo/LeagueOfPhysical-Server --workflow gameserver-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId'); echo "run $RID"
gh run watch "$RID" --repo Baeinsoo/LeagueOfPhysical-Server --exit-status --interval 30 || echo "실패 — gh run view $RID --log-failed"
```
Expected: Unity 빌드 → 이미지 push → 태그 bump 성공. (첫 IL2CPP 빌드는 오래 걸림.)

- [ ] **Step 2: 이미지 + ConfigMap 검증**

```bash
SHA=$(cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server && git rev-parse --short HEAD)
docker manifest inspect re5nardo/game-server:$SHA >/dev/null 2>&1 && echo "IMAGE PUSHED: $SHA"
cd /Users/insoobae/workspace/LOP/infrastructure && git pull origin main --quiet
grep GAME_SERVER_IMAGE k8s/apps/backend/game-server-config/configmap.yaml
```
Expected: 이미지 존재, ConfigMap의 `GAME_SERVER_IMAGE`가 `re5nardo/game-server:<sha>`.

- [ ] **Step 3: ArgoCD 반영 + room-server가 값 참조 확인**

```bash
kubectl -n argocd annotate application backend argocd.argoproj.io/refresh=hard --overwrite >/dev/null; sleep 20
kubectl get configmap game-server-config -n default -o jsonpath='{.data.GAME_SERVER_IMAGE}'; echo
kubectl get application backend -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'; echo
```
Expected: 클러스터의 ConfigMap `GAME_SERVER_IMAGE`가 새 sha, backend Synced/Healthy. (room-server는 재시작 시 이 env를 읽어 매치 pod를 새 이미지로 생성 — 배선 완료. 실제 pod 기동은 범위 밖.)

- [ ] **Step 4: 로컬 dev Build 정리 (선택)**

LeagueOfPhysical-Server/Build/의 1.4GB 로컬 dev 산출물(679MB 디버그 백업 포함)은 gitignore라 레포엔 없지만 디스크 점유. 필요 시 정리:
```bash
echo "로컬 Build 크기: $(du -sh /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server/Build 2>/dev/null | cut -f1)"
# rm -rf 는 사용자 판단 (다음 로컬 빌드 시 재생성)
```

---

### Task 7: 문서

**Files:**
- Modify: `infrastructure/README.md` 또는 `k8s/argocd/README.md`

- [ ] **Step 1: 문서 갱신**

게임서버 배포 흐름 추가: LeagueOfPhysical-Server의 `gameserver-deploy` 버튼(셀프호스트) → Unity 빌드 → `re5nardo/game-server:<sha>` → `game-server-config` ConfigMap bump → room-server가 매치 시 참조. 러너 접속·재발급 절차, room-server의 `GAME_SERVER_IMAGE` env 참조 명시.

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git add -A && git commit -m "docs: Phase 3(게임서버 CI) 반영" && git push origin main
```

---

## 완료 기준 (Phase 3 검증)

1. 셀프호스트 러너(맥) 온라인
2. BuildScript로 batchmode Linux 서버 빌드 성공(로컬 검증 + CI)
3. `gameserver-deploy` 버튼 → `re5nardo/game-server:<sha>` 빌드·푸시
4. infra `game-server-config` ConfigMap이 sha로 bump, ArgoCD Synced
5. room-server가 하드코딩 대신 `GAME_SERVER_IMAGE` env 참조(fallback 유지)

## 의도적으로 Phase 3에서 제외

- 실제 매치 생성으로 game-server pod 기동 E2E — 별도. 로컬 arm64에서 amd64 이미지 실행은 에뮬레이션/arm64 빌드 필요.
- 게임서버 멀티아치(amd64+arm64) 이미지 — Unity 단일 아키 빌드라 2회 빌드 필요. 클라우드(amd64) 갈 때 정리.
- room.service.ts의 `getPublicIP` 하드코딩 `localhost` 해소 — 클라우드 노출 시 과제.
- ConfigMap 변경 시 room-server 자동 재시작(configMapGenerator 해시) — 지금은 재시작 시 반영으로 충분.
- push 자동 트리거 — 버튼만.
- Unity 클라이언트/어드레서블 → Phase 4.
