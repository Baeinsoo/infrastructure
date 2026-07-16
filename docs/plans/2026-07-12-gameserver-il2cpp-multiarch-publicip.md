# 게임서버 하드닝 (IL2CPP + 멀티아치 + getPublicIP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 게임서버를 IL2CPP + 멀티아치(amd64+arm64)로 빌드하고 room-server의 public IP 하드코딩을 ConfigMap/env 주입으로 바꿔, 로컬 arm64 클러스터에서 게임서버 pod를 실제로 기동한다.

**Architecture:** Unity는 한 번에 한 아키텍처만 빌드하므로 BuildScript를 아키텍처 파라미터화(env `LOP_BUILD_ARCH`)해 amd64·arm64 각각 빌드하고, 두 이미지를 `docker manifest`로 멀티아치 태그(`re5nardo/game-server:<sha>`)에 합친다. IL2CPP sysroot는 Server manifest의 `com.unity.sdk.linux-*` 패키지가 제공(amd64는 실측 확인됨, arm64 sysroot 다운로드는 Task 1에서 선검증). room-server는 `GAME_SERVER_PUBLIC_IP` env(game-server-config ConfigMap)를 읽는다.

**Tech Stack:** Unity 6000.3.16f1 (Linux Dedicated Server, IL2CPP, x86_64+arm64), GitHub Actions(셀프호스트 맥 러너), docker + `docker manifest`(멀티아치), Node/TS(room-server), ArgoCD/Kustomize(기구축).

**설계 문서:** `infrastructure/docs/specs/2026-07-12-gameserver-il2cpp-multiarch-publicip-design.md`
**선행:** Phase 3(게임서버 CI) 완료. NuGet CI 복원 리팩터 완료(Server 워크플로에 `nugetforunity restore` 스텝 존재).

---

## Global Constraints

**결정 사항 (2026-07-12, 사용자 확정):**
- **IL2CPP 전환**: amd64 IL2CPP 빌드는 로컬 실측 성공(`Build OK`, `GameAssembly.so`). arm64 Linux 서버는 **IL2CPP 전용**(Unity에 arm64 Mono variation 없음).
- **멀티아치 amd64+arm64**: 목표 = 로컬 arm64 클러스터(docker-desktop, arm64 단일노드)에서 pod 실제 기동.
- **getPublicIP**: ConfigMap/env 주입, 기본값 `localhost`(로컬 docker-desktop은 NodePort가 localhost에 노출돼 동작).

**현재 사실 (조사·실측 확정):**
- Server manifest에 `com.unity.sdk.linux-arm64: 1.1.0`, `com.unity.sdk.linux-x86_64: 1.1.0`, `com.unity.toolchain.macos-arm64-linux: 1.1.0`가 **미커밋 WIP**로 추가돼 있음(커밋된 manifest엔 Linux 패키지 없음). 이 SDK 패키지가 IL2CPP Linux sysroot 제공.
- Linux IL2CPP 툴체인(llvm-9.0.1, 389MB)이 `~/Library/Unity/cache/sysroots/darwin-arm64-linux-x86_64`에 캐시. **arm64 타깃 sysroot는 캐시에 없음** — arm64 빌드 시 다운로드/설치 선행 필요(Task 1 검증).
- `BuildScript.BuildLinuxServer`(`Assets/Scripts/Editor/BuildScript.cs`)는 현재 x86_64/Mono2j 하드코딩. 산출 `GameServer/Build/lop-server.x86_64`.
- `GameServer/Dockerfile`: `ubuntu:20.04`(멀티아치 지원), `COPY Build/ /app/`, `chmod +x /app/lop-server.x86_64`, `CMD ["/app/lop-server.x86_64",...]`.
- 워크플로 `gameserver-deploy.yml`: docker 스텝이 `working-directory: GameServer` + `docker build --platform linux/amd64 -t re5nardo/game-server:<sha> .`(단일). 러너는 launchd라 keychain 접근 불가 → 임시 DOCKER_CONFIG inline auth 패턴.
- room-server `room.service.ts:179`: `const ip = /*await k8sUtils.getPublicIP(pod.metadata?.name)*/'localhost';`. room-server는 이미 `game-server-config` ConfigMap을 `envFrom`으로 받음(Phase 3).
- infra `k8s/apps/backend/game-server-config/configmap.yaml`: `data.GAME_SERVER_IMAGE`만 있음.
- Docker Desktop 데몬이 꺼져 있으면 docker push 실패(`Cannot connect to the Docker daemon`) — 실행 전 데몬 기동 필요.

**불변 규칙:**
1. Unity 산출물(GameServer/Build*, Library)은 git 커밋 안 함(gitignore). CI 매번 fresh 빌드.
2. 이미지 태그는 sha. `re5nardo/game-server:<sha>`는 **멀티아치 매니페스트**(amd64+arm64). 아치별 임시 태그는 `<sha>-amd64`/`<sha>-arm64`.
3. 콘텐츠 아님 — 이 작업은 게임서버 이미지 + room-server 배선. room-server는 `GAME_SERVER_PUBLIC_IP` env(ConfigMap)에서 IP를 읽고, 없으면 `localhost` fallback.
4. 게임서버 워크플로는 셀프호스트 러너에서만(`runs-on: self-hosted`). docker/git ambient. NuGet은 `nugetforunity restore`로 복원(기존 스텝).
5. room-server는 ConfigMap 변경을 pod 재시작 시 반영(Phase 3와 동일 — 런타임 자동 리로드 아님).

**검증:** 워크플로 성공, `docker manifest inspect re5nardo/game-server:<sha>`가 amd64+arm64 2아치, infra ConfigMap `GAME_SERVER_IMAGE` sha + `GAME_SERVER_PUBLIC_IP` 존재, ArgoCD Synced, **매치 생성 시 게임서버 pod가 arm64 노드에서 Running**, room.ip가 `GAME_SERVER_PUBLIC_IP` 값.

---

### Task 1: manifest 커밋 + BuildScript 아키텍처 파라미터화 + arm64 sysroot 실측

IL2CPP 전환과 멀티아치의 토대. arm64 sysroot 다운로드가 미검증이므로 **이 태스크에서 로컬로 amd64·arm64 IL2CPP 빌드를 둘 다 성공**시키는 것이 완료 조건이다.

**Files:**
- Modify: `LeagueOfPhysical-Server/Packages/manifest.json` (sdk.linux WIP 커밋)
- Modify: `LeagueOfPhysical-Server/Assets/Scripts/Editor/BuildScript.cs` (IL2CPP + arch 파라미터)

**Interfaces:**
- Produces: `BuildScript.BuildLinuxServer` — env `LOP_BUILD_ARCH`(`x86_64`|`arm64`, 기본 `x86_64`)로 아치 선택. 산출 = `GameServer/Build-<arch>/lop-server.x86_64`. Task 4 워크플로가 아치별로 2회 호출.

- [ ] **Step 1: arm64 아키텍처 설정 API 실측 (introspection)**

Unity 6의 Linux 서버 아키텍처 설정 API를 확정한다. batchmode 리플렉션으로 후보를 출력:
```bash
UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
cat > Assets/Editor/_ArchProbe.cs <<'CS'
using System.Linq; using System.Reflection; using UnityEditor; using UnityEngine;
public static class _ArchProbe {
  public static void Dump() {
    var m = typeof(PlayerSettings).GetMethods(BindingFlags.Public|BindingFlags.Static)
      .Where(x => x.Name.Contains("Architecture")).Select(x => x.Name+"("+string.Join(",", x.GetParameters().Select(p=>p.ParameterType.Name))+")");
    Debug.Log("ARCH_API: "+string.Join(" | ", m.Distinct()));
    EditorApplication.Exit(0);
  }
}
CS
"$UNITY" -batchmode -quit -nographics -projectPath . -executeMethod _ArchProbe.Dump -logFile - 2>&1 | grep ARCH_API
rm -f Assets/Editor/_ArchProbe.cs Assets/Editor/_ArchProbe.cs.meta
```
**확정됨 (2026-07-12 실측·디컴파일):** ⚠️ `PlayerSettings.SetArchitecture`는 **iOS/tvOS/visionOS 전용**이라 Linux에 안 먹고, `EditorUserBuildSettings.SetPlatformSettings("Standalone","StandaloneLinux64","Architecture",...)`도 **저장 안 됨**(둘 다 x86_64만 나옴). 빌드 확장(`ikdasm`)을 뜯어보니 실제 저장소는 **`UnityEditor.LinuxStandalone.UserBuildSettings.architecture`**(타입 `OSArchitecture`, Build Profile/classic 백킹). 확장 어셈블리 직접참조 불가라 **리플렉션**으로 설정. 상세는 memory `unity6-linux-arm64-build-api`. Step 3 코드는 이 방식(아래 `SetLinuxArchitecture`). **이미 구현·main 반영됨**(Server `847a18b`, amd64 ELF x86-64 / arm64 ELF ARM aarch64 실측 성공).

- [ ] **Step 2: manifest의 sdk.linux 패키지 커밋 (피처 브랜치)**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
git checkout -b feature/gameserver-il2cpp-multiarch
git add Packages/manifest.json Packages/packages-lock.json
git status --short | grep -E "manifest.json|packages-lock"
git commit -m "build: Linux IL2CPP sysroot 패키지(sdk.linux-arm64/x86_64) 추가"
```
(URP 등 다른 WIP는 스테이징하지 않음 — manifest/lock만. packages-lock에 sdk.linux 해소본 포함.)

- [ ] **Step 3: BuildScript를 IL2CPP + 아치 파라미터화**

`Assets/Scripts/Editor/BuildScript.cs` 전체 교체:
```csharp
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class BuildScript
{
    // Linux 아키텍처 지정 — 실제 저장소는 UnityEditor.LinuxStandalone.UserBuildSettings.architecture.
    // (PlayerSettings.SetArchitecture=iOS전용, SetPlatformSettings=미적용) 확장 어셈블리는 리플렉션으로.
    static void SetLinuxArchitecture(string arch) // "x86_64" | "arm64"
    {
        var asm = System.AppDomain.CurrentDomain.GetAssemblies()
            .FirstOrDefault(a => a.GetType("UnityEditor.LinuxStandalone.UserBuildSettings") != null);
        if (asm == null) throw new System.Exception("LinuxStandalone extension assembly not found");
        var ubs = asm.GetType("UnityEditor.LinuxStandalone.UserBuildSettings");
        var helper = asm.GetType("UnityEditor.LinuxStandalone.LinuxArchitectureHelper");
        var fromStr = helper.GetMethod("GetArchitectureFromString", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
        var archProp = ubs.GetProperty("architecture", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
        archProp.SetValue(null, fromStr.Invoke(null, new object[] { arch }));
    }

    // CI: LOP_BUILD_ARCH=x86_64|arm64 Unity -batchmode -quit -nographics -projectPath . \
    //     -executeMethod BuildScript.BuildLinuxServer -logFile -
    // 아치별로 산출 디렉토리를 분리(GameServer/Build-<arch>)해 멀티아치 도커 빌드에 각각 쓴다.
    public static void BuildLinuxServer()
    {
        var arch = (System.Environment.GetEnvironmentVariable("LOP_BUILD_ARCH") ?? "x86_64").Trim().ToLowerInvariant();
        if (arch != "x86_64" && arch != "arm64")
        {
            Debug.LogError($"Build FAILED: LOP_BUILD_ARCH must be x86_64 or arm64, got '{arch}'");
            EditorApplication.Exit(1);
            return;
        }

        string outputDir = $"GameServer/Build-{arch}";
        string exe = outputDir + "/lop-server.x86_64"; // 실행파일명은 유지(Dockerfile CMD 고정)

        var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
        if (scenes.Length == 0)
        {
            Debug.LogError("Build FAILED: no enabled scenes in EditorBuildSettings");
            EditorApplication.Exit(1);
            return;
        }

        // Dedicated Server 서브타겟 + IL2CPP. arm64는 IL2CPP 전용(Unity에 arm64 Mono 없음).
        // sysroot는 manifest의 com.unity.sdk.linux-* 패키지가 제공.
        EditorUserBuildSettings.standaloneBuildSubtarget = StandaloneBuildSubtarget.Server;
        PlayerSettings.SetScriptingBackend(NamedBuildTarget.Server, ScriptingImplementation.IL2CPP);
        SetLinuxArchitecture(arch); // 아래 헬퍼 — UserBuildSettings.architecture(리플렉션). Server 서브타겟 뒤에 호출.

        var options = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = exe,
            target = BuildTarget.StandaloneLinux64,
            subtarget = (int)StandaloneBuildSubtarget.Server,
            options = BuildOptions.None,
        };

        try
        {
            BuildReport report = BuildPipeline.BuildPlayer(options);
            BuildSummary summary = report.summary;
            if (summary.result != BuildResult.Succeeded)
            {
                Debug.LogError($"Build FAILED: arch={arch}, result={summary.result}, errors={summary.totalErrors}");
                EditorApplication.Exit(1);
                return;
            }
            Debug.Log($"Build OK: arch={arch}, {summary.outputPath}, size={summary.totalSize} bytes");
            EditorApplication.Exit(0);
        }
        catch (System.Exception e)
        {
            Debug.LogError($"Build threw: {e}");
            EditorApplication.Exit(1);
        }
    }
}
```
(Step 1 출력이 `SetArchitecture` 아닌 다른 시그니처면 그 호출로 교체. 인자 문자열도 introspection이 알려주는 허용값[`x64`/`ARM64` 등]으로 맞춘다.)

- [ ] **Step 4: 로컬 amd64 IL2CPP 빌드 검증**

에디터 닫힌 상태에서:
```bash
UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
export PATH="$HOME/.dotnet/tools:$PATH"; dotnet tool restore >/dev/null 2>&1; dotnet tool run nugetforunity restore . >/dev/null 2>&1
LOP_BUILD_ARCH=x86_64 "$UNITY" -batchmode -quit -nographics -projectPath . \
  -executeMethod BuildScript.BuildLinuxServer -logFile /tmp/build-amd64.log 2>&1
grep -E "Build OK: arch=x86_64|Build FAILED|Unable to find" /tmp/build-amd64.log | tail -3
file GameServer/Build-x86_64/lop-server.x86_64
```
Expected: `Build OK: arch=x86_64`, `ELF 64-bit LSB ... x86-64`. (sysroot 캐시에 있어 통과 — 실측됨.)

- [ ] **Step 5: 로컬 arm64 IL2CPP 빌드 검증 (핵심 미검증 스텝)**

```bash
UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
LOP_BUILD_ARCH=arm64 "$UNITY" -batchmode -quit -nographics -projectPath . \
  -executeMethod BuildScript.BuildLinuxServer -logFile /tmp/build-arm64.log 2>&1
grep -E "Build OK: arch=arm64|Build FAILED|Unable to find|sysroot|Sysroot" /tmp/build-arm64.log | tail -5
file GameServer/Build-arm64/lop-server.x86_64
```
Expected: `Build OK: arch=arm64`, `ELF 64-bit LSB ... ARM aarch64`.
**실패 시(arm64 sysroot 부재)**: 로그의 sysroot 경로 에러 확인 → Unity Hub로 arm64 Linux 서버 빌드 모듈/sysroot 설치(`~/Library/Unity/cache/sysroots/`에 `*linux-arm64*` 생성 확인) 후 재시도. 이 스텝이 arm64 멀티아치의 실현가능성 게이트다.

- [ ] **Step 6: Commit (BuildScript) + main 병합·push**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
git add Assets/Scripts/Editor/BuildScript.cs
git commit -m "build: IL2CPP 전환 + Linux 아키텍처 파라미터화(LOP_BUILD_ARCH)"
git checkout main && git merge --no-ff feature/gameserver-il2cpp-multiarch -m "Merge feature/gameserver-il2cpp-multiarch (Task 1)"
git push origin main
```
(로컬 main이 origin보다 뒤면 `git fetch origin main && git merge origin/main --no-edit` 후 push. Build-* 산출물은 gitignore.)

---

### Task 2: Dockerfile 멀티아치 컨텍스트 정합

Dockerfile이 아치별 산출 디렉토리(`Build-<arch>`)를 받아 이미지를 만들 수 있게 한다. 실행파일명은 `lop-server.x86_64`로 유지(CMD 고정).

**Files:**
- Modify: `LeagueOfPhysical-Server/GameServer/Dockerfile`

**Interfaces:**
- Consumes: Task 1의 `GameServer/Build-<arch>/` 산출물
- Produces: 빌드 인자 `BUILD_DIR`로 아치별 산출을 COPY하는 Dockerfile. Task 4가 `--build-arg BUILD_DIR=Build-<arch>`로 호출.

- [ ] **Step 1: Dockerfile을 BUILD_DIR 인자화**

`GameServer/Dockerfile`의 `COPY Build/ /app/` 부분을 인자화. 아래처럼 `ARG` 추가 + COPY 경로 변경(파일 상단 `FROM` 아래에 ARG, COPY 라인 교체):
```dockerfile
FROM ubuntu:20.04
ARG BUILD_DIR=Build
ENV DEBIAN_FRONTEND=noninteractive
```
그리고 기존 `COPY Build/ /app/`를:
```dockerfile
COPY ${BUILD_DIR}/ /app/
```
로 교체. (나머지 apt 설치·WORKDIR·chmod·EXPOSE·CMD 불변. `lop-server.x86_64` 실행파일명 유지.)

- [ ] **Step 2: 아치별 로컬 도커 빌드 검증 (Docker Desktop 실행 필요)**

```bash
open -a Docker; until docker info >/dev/null 2>&1; do sleep 2; done   # 데몬 기동 대기
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server/GameServer
docker build --platform linux/amd64 --build-arg BUILD_DIR=Build-x86_64 -t game-server:test-amd64 .
docker build --platform linux/arm64 --build-arg BUILD_DIR=Build-arm64 -t game-server:test-arm64 .
docker image inspect game-server:test-amd64 --format 'amd64 arch={{.Architecture}}'
docker image inspect game-server:test-arm64 --format 'arm64 arch={{.Architecture}}'
```
Expected: 두 이미지 빌드 성공, `arch=amd64` / `arch=arm64`. (Task 1의 Build-* 산출물이 있어야 함.)

- [ ] **Step 3: Commit**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
git add GameServer/Dockerfile
git commit -m "chore(docker): 게임서버 Dockerfile을 BUILD_DIR 인자화(멀티아치)"
git push origin main
```

---

### Task 3: getPublicIP 주입 — room-server env + ConfigMap

room-server의 하드코딩 `'localhost'`를 `GAME_SERVER_PUBLIC_IP` env로 바꾸고, infra ConfigMap에 키를 추가한다. Unity 빌드와 독립.

**Files:**
- Modify: `lop-backend/apps/room-server/src/services/room.service.ts:179`
- Modify: `infrastructure/k8s/apps/backend/game-server-config/configmap.yaml`

**Interfaces:**
- Produces: room.ip = `process.env.GAME_SERVER_PUBLIC_IP || 'localhost'`. ConfigMap이 `GAME_SERVER_PUBLIC_IP` 제공.

- [ ] **Step 1: room.service.ts 하드코딩 → env**

`apps/room-server/src/services/room.service.ts`의 179행:
```ts
            const ip = /*await k8sUtils.getPublicIP(pod.metadata?.name)*/'localhost';
```
을 다음으로 교체:
```ts
            const ip = process.env.GAME_SERVER_PUBLIC_IP || 'localhost';
```
(다른 로직·nodePort·검증 불변. fallback으로 localhost 유지.)

- [ ] **Step 2: room-server 빌드 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
pnpm --filter @lop/database run generate
pnpm --filter room-server run build
```
Expected: 타입체크·빌드 통과.

- [ ] **Step 3: ConfigMap에 GAME_SERVER_PUBLIC_IP 추가**

`infrastructure/k8s/apps/backend/game-server-config/configmap.yaml`의 `data:`에 한 줄 추가:
```yaml
data:
  GAME_SERVER_IMAGE: re5nardo/game-server:07731b0
  GAME_SERVER_PUBLIC_IP: localhost   # 로컬 docker-desktop NodePort는 localhost 노출. 클라우드 이전 시 노드/LB IP로 교체
```

- [ ] **Step 4: 렌더 검증 + 커밋 (양 레포, 피처 브랜치)**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
kubectl kustomize k8s/apps/backend | grep -A4 "name: game-server-config" | grep GAME_SERVER_PUBLIC_IP
git add k8s/apps/backend/game-server-config/configmap.yaml
git commit -m "feat(k8s): game-server-config에 GAME_SERVER_PUBLIC_IP 추가(room-server 주입)" && git push origin main
cd /Users/insoobae/workspace/LOP/lop-backend
git checkout -b feature/room-public-ip-env 2>/dev/null || git checkout feature/room-public-ip-env
git add apps/room-server/src/services/room.service.ts
git commit -m "feat(room): public IP를 GAME_SERVER_PUBLIC_IP env에서 읽음(하드코딩 제거)"
git checkout main && git merge --no-ff feature/room-public-ip-env -m "Merge feature/room-public-ip-env" && git push origin main
```
Expected: kustomize 렌더에 `GAME_SERVER_PUBLIC_IP: localhost` 표시.

- [ ] **Step 5: room-server 재배포 (코드 반영)**

```bash
gh workflow run backend-deploy.yml --repo Baeinsoo/lop-backend -f app=room-server
sleep 8; RID=$(gh run list --repo Baeinsoo/lop-backend --workflow backend-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RID" --repo Baeinsoo/lop-backend --exit-status --interval 30 || echo "실패 — gh run view $RID --log-failed"
```
Expected: room-server 새 sha 이미지 롤아웃. 이후 ArgoCD sync로 ConfigMap+새 이미지 반영.

---

### Task 4: 멀티아치 게임서버 워크플로

`gameserver-deploy.yml`의 단일아치 빌드를 아치별 2회 Unity 빌드 + 아치별 도커 이미지 + `docker manifest`로 교체.

**Files:**
- Modify: `LeagueOfPhysical-Server/.github/workflows/gameserver-deploy.yml`

**Interfaces:**
- Consumes: BuildScript(Task 1), Dockerfile BUILD_DIR(Task 2)
- Produces: `re5nardo/game-server:<sha>` 멀티아치 매니페스트(amd64+arm64) push + infra ConfigMap bump.

- [ ] **Step 1: Unity 빌드 스텝을 아치 2회로 교체**

`gameserver-deploy.yml`의 "Unity Linux 서버 빌드 (batchmode)" 스텝을 아래로 교체(NuGet 복원 스텝 뒤, docker 스텝 앞):
```yaml
      - name: Unity IL2CPP 빌드 (amd64 + arm64)
        run: |
          set -eo pipefail
          UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
          for ARCH in x86_64 arm64; do
            echo "::group::Unity build $ARCH"
            if ! LOP_BUILD_ARCH=$ARCH "$UNITY" -batchmode -quit -nographics -projectPath . \
                  -executeMethod BuildScript.BuildLinuxServer -logFile - > unity-$ARCH.log 2>&1; then
              echo "::error::Unity build $ARCH failed"; tail -80 unity-$ARCH.log; exit 1
            fi
            tail -5 unity-$ARCH.log
            test -f GameServer/Build-$ARCH/lop-server.x86_64
            echo "::endgroup::"
          done
```

- [ ] **Step 2: docker 스텝을 멀티아치(2 이미지 + manifest)로 교체**

"도커 이미지 빌드·푸시 (amd64)" 스텝을 아래로 교체:
```yaml
      - name: 도커 멀티아치 빌드·푸시 (amd64+arm64 manifest)
        working-directory: GameServer
        env:
          DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: |
          set -e
          # launchd 러너는 keychain 접근 불가 → 임시 DOCKER_CONFIG inline auth로 우회
          export DOCKER_CONFIG="$(mktemp -d)"
          trap 'rm -rf "$DOCKER_CONFIG"' EXIT
          AUTH="$(printf '%s:%s' "$DOCKERHUB_USERNAME" "$DOCKERHUB_TOKEN" | base64)"
          printf '{"auths":{"https://index.docker.io/v1/":{"auth":"%s"}}}' "$AUTH" > "$DOCKER_CONFIG/config.json"
          SHA="${{ steps.tag.outputs.sha }}"
          BASE="re5nardo/game-server"
          docker build --platform linux/amd64 --build-arg BUILD_DIR=Build-x86_64 -t "$BASE:$SHA-amd64" .
          docker push "$BASE:$SHA-amd64"
          docker build --platform linux/arm64 --build-arg BUILD_DIR=Build-arm64 -t "$BASE:$SHA-arm64" .
          docker push "$BASE:$SHA-arm64"
          # 멀티아치 매니페스트로 합침 (아치별 산출이 달라 buildx 단일컨텍스트 불가)
          docker manifest rm "$BASE:$SHA" 2>/dev/null || true
          docker manifest create "$BASE:$SHA" --amend "$BASE:$SHA-amd64" --amend "$BASE:$SHA-arm64"
          docker manifest push "$BASE:$SHA"
          echo "pushed multiarch $BASE:$SHA"
```
(infra bump 스텝은 불변 — `GAME_SERVER_IMAGE`를 `re5nardo/game-server:$SHA`로 sed. 그 값이 멀티아치 매니페스트를 가리킴.)

- [ ] **Step 3: YAML 검증 + 커밋·push**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server
ruby -ryaml -e "YAML.load_file('.github/workflows/gameserver-deploy.yml'); puts 'YAML OK'"
git add .github/workflows/gameserver-deploy.yml
git commit -m "ci: 게임서버 멀티아치 빌드(amd64+arm64 IL2CPP → docker manifest)"
git push origin main
```

---

### Task 5: 첫 실행 + 끝-투-끝 검증 (멀티아치 + pod 기동)

**Files:** 없음 (실행·검증)

- [ ] **Step 1: Docker Desktop 기동 확인 후 워크플로 실행**

```bash
open -a Docker; until docker info >/dev/null 2>&1; do sleep 2; done; echo "docker up"
gh workflow run gameserver-deploy.yml --repo Baeinsoo/LeagueOfPhysical-Server
sleep 8; RID=$(gh run list --repo Baeinsoo/LeagueOfPhysical-Server --workflow gameserver-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId'); echo "run $RID"
gh run watch "$RID" --repo Baeinsoo/LeagueOfPhysical-Server --exit-status --interval 30 || echo "실패 — gh run view $RID --log-failed"
```
Expected: 2아치 Unity 빌드 → 2 이미지 push → manifest push → ConfigMap bump 성공. (IL2CPP 2회라 오래 걸림.)

- [ ] **Step 2: 멀티아치 매니페스트 검증**

```bash
SHA=$(cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Server && git rev-parse --short HEAD)
docker manifest inspect re5nardo/game-server:$SHA | grep -E "architecture|amd64|arm64"
```
Expected: `"architecture": "amd64"`와 `"architecture": "arm64"` 둘 다.

- [ ] **Step 3: ArgoCD 반영 + ConfigMap 검증**

```bash
cd /Users/insoobae/workspace/LOP/infrastructure && git pull origin main --quiet
grep -E "GAME_SERVER_IMAGE|GAME_SERVER_PUBLIC_IP" k8s/apps/backend/game-server-config/configmap.yaml
kubectl -n argocd annotate application backend argocd.argoproj.io/refresh=hard --overwrite >/dev/null; sleep 20
kubectl get configmap game-server-config -n default -o jsonpath='{.data.GAME_SERVER_IMAGE}{"\n"}{.data.GAME_SERVER_PUBLIC_IP}{"\n"}'
kubectl get application backend -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'; echo
```
Expected: ConfigMap `GAME_SERVER_IMAGE`=새 sha, `GAME_SERVER_PUBLIC_IP`=localhost, backend Synced/Healthy.

- [ ] **Step 4: 매치 생성 → arm64 pod 기동 검증 (Phase 3가 미룬 것)**

room-server로 룸을 생성해 게임서버 pod가 arm64 노드에서 뜨는지 확인. room-server API로 룸 생성(ingress 경유; 정확한 엔드포인트는 room-server 라우트 확인):
```bash
# room 생성 트리거 (실제 매칭 플로우 또는 room-server 직접 호출 — 프로젝트 매칭 API에 맞춤)
kubectl get pods -n default -l app=room-pod -w &   # 게임서버 pod 관찰
# ... 룸 생성 요청 ...
# 관찰 후:
kubectl get pods -n default -l app=room-pod -o wide
POD=$(kubectl get pods -n default -l app=room-pod -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -n default -o jsonpath='{.status.phase}{"\n"}'
kubectl describe node docker-desktop | grep -i architecture   # arm64 노드 확인
```
Expected: game-server pod가 `Running`(arm64 이미지 pull 성공 — 에뮬레이션 없이 네이티브). 이전엔 amd64라 arm64 노드에서 실패했던 지점.

- [ ] **Step 5: room.ip 주입 검증**

```bash
# 생성된 room의 ip/port 확인 (room-server DB 또는 API 응답)
kubectl get pod -n default -l app=room-server -o jsonpath='{.items[0].spec.containers[0].env}' 2>/dev/null | tr ',' '\n' | grep -i PUBLIC_IP || \
  kubectl get pod -n default -l app=room-server -o jsonpath='{.items[0].spec.containers[0].envFrom[*].configMapRef.name}'; echo
```
Expected: room-server가 `game-server-config`(GAME_SERVER_PUBLIC_IP 포함) envFrom, room.ip=localhost. 클라가 localhost:nodePort로 접속 가능(로컬).

---

### Task 6: 문서 + 이월 정리

**Files:**
- Modify: `infrastructure/README.md`

- [ ] **Step 1: README 게임서버 섹션 갱신**

"게임서버 배포 (CI, Phase 3)" 섹션에 반영: IL2CPP + **멀티아치(amd64+arm64)** 빌드, `re5nardo/game-server:<sha>`가 멀티아치 매니페스트, room-server가 `GAME_SERVER_PUBLIC_IP`(game-server-config ConfigMap) 주입, 로컬 arm64 pod 기동 지원. arm64 sysroot 설치 필요시 절차 명시.

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git add -A && git commit -m "docs: 게임서버 IL2CPP+멀티아치+getPublicIP 반영" && git push origin main
```

- [ ] **Step 2: 이월/후속 명문화 + memory 갱신**

- Docker Desktop 상시 기동 필요(러너 docker push) — 데몬 자동 기동은 미해결.
- 클라우드 이전 시 `GAME_SERVER_PUBLIC_IP`를 노드/LB IP로, getPublicIP k8s downward API 자동조회 검토.
- DOCKERHUB/INFRA 토큰 rotate(기존 이월).
- `deployment-system-project` memory에 이 작업 완료 반영.

---

## 완료 기준

1. `gameserver-deploy` 버튼 → `re5nardo/game-server:<sha>` **멀티아치 매니페스트(amd64+arm64)** push
2. IL2CPP 빌드(Mono 탈피), arm64 IL2CPP 로컬·CI 성공
3. infra ConfigMap `GAME_SERVER_IMAGE` bump + `GAME_SERVER_PUBLIC_IP` 존재, ArgoCD Synced
4. 매치 생성 시 게임서버 pod가 **arm64 노드에서 Running**(Phase 3 미룬 pod 기동 닫힘)
5. room-server가 `GAME_SERVER_PUBLIC_IP` env로 room.ip 설정

## 의도적으로 범위에서 제외

- 게임플레이 풀 루프(로비→게임→종료) 검증 — pod 기동·접속까지가 범위.
- 실제 클라우드 배포(EKS/GKE, 공인 IP/LB) — ConfigMap 값 교체로 확장 가능하게만.
- Docker Desktop 자동 기동, getPublicIP k8s 자동조회 — 클라우드 과제.
