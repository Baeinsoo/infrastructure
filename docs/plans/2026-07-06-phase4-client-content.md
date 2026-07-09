# Phase 4: Unity 클라이언트 앱(APK) + 어드레서블 콘텐츠 파이프라인 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LeagueOfPhysical-Client을 버튼 하나로 (③a) Android APK를 batchmode 빌드해 `s3://lop-client/builds/<sha>/`에 버전별로 보존하고, (③b) 어드레서블 콘텐츠를 batchmode 빌드해 `s3://lop-assets/dev/Android/`에 배포하는 **서로 독립된 두 파이프라인**을 구축한다. 앱은 가끔(코드 변경 시), 콘텐츠는 수시로 — 버튼이 따로 있고 서로를 기다리지 않는다.

**Architecture:** Phase 3의 셀프호스트 러너 방식을 재사용하되 **Client 전용 2번째 러너**를 같은 맥에 등록(개인계정이라 org 공유 러너 불가). 두 워크플로 모두 셀프호스트 러너에서 Unity batchmode(`-buildTarget Android`)로 실행. 산출물은 **k8s/ArgoCD를 거치지 않고 S3로 직행**(클라이언트가 S3에서 직접 pull) — 따라서 git push·infra bump·INFRA_REPO_TOKEN이 전혀 없고, 필요한 자격증명은 **AWS 정적 키(전용 IAM 사용자)**뿐이다. 콘텐츠는 앱 릴리스가 남긴 `addressables_content_state.bin`을 기준점으로 "Update a Previous Build"(증분) 빌드를 수행해 설치된 앱과 카탈로그 호환을 유지한다.

**Tech Stack:** Unity 6000.3.16f1 (Android, Mono2x, ARMv7, 디버그 서명), Addressables 2.9.1, GitHub Actions(셀프호스트 러너), AWS S3(ap-northeast-2), IAM.

**설계 문서:** `infrastructure/docs/specs/2026-07-05-deployment-system-design.md` (③a/③b: 91–103행)
**선행:** Phase 0~3 완료. Phase 3 게임서버 러너/워크플로 패턴(`LeagueOfPhysical-Server/.github/workflows/gameserver-deploy.yml`)을 템플릿으로 재사용.

---

## Global Constraints

**사용자 확정 결정 (2026-07-06):**
1. **러너:** Client 전용 2번째 셀프호스트 러너를 같은 맥에 별도 인스턴스(`~/actions-runner-lop-client` + 2번째 launchd 서비스)로 등록. Baeinsoo는 개인 계정이라 org 레벨 공유 러너 불가 — GitHub repo 러너는 한 레포에만 매인다.
2. **AWS 자격증명:** 브라우저 `aws login`(root, 세션 만료됨)에 의존하지 않는다. **전용 IAM 사용자 + 정적 키**를 Client 레포 GitHub Secrets(`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`)로 주입. 권한은 `lop-assets`·`lop-client` 버킷에만 한정(최소권한).
3. **APK 서명:** 디버그 서명 유지(프로젝트에 커스텀 키스토어 미설정). 시크릿 불필요. 스토어 배포는 범위 밖.
4. **검증 범위:** S3 산출물까지 — APK가 `s3://lop-client/builds/<sha>/`에, 콘텐츠가 `s3://lop-assets/dev/Android/`에 올라가고 `content_state.bin` 보존·`latest` 포인터 갱신까지 확인. 실기기 설치·구동은 범위 밖.

**현재 사실 (조사 확정):**
- Client: `github.com/Baeinsoo/LeagueOfPhysical-Client`(main, **public**), Unity 6000.3.16f1(러너 Unity와 동일). Android Build Support 모듈 설치됨(맥).
- **batchmode 빌드 스크립트 전무** — APK/콘텐츠 어느 쪽도 `-executeMethod` 진입점이 없다. 콘텐츠는 지금까지 에디터 GUI(및 UnityMCP)로만 빌드됨. 신규 `BuildScript.cs` 작성 필요.
- Addressables 2.9.1. 활성 프로파일 = **dev**. dev의 `Remote.LoadPath` = `https://lop-assets.s3.ap-northeast-2.amazonaws.com/dev/[BuildTarget]`, `Remote.BuildPath` = `ServerData/[BuildTarget]`. `m_BuildRemoteCatalog=1`(원격 카탈로그). 콘텐츠 산출 → 프로젝트 루트 `ServerData/[BuildTarget]/`.
- **Android 콘텐츠는 한 번도 빌드된 적 없음** — `ServerData/Android` 없음, `Assets/AddressableAssetsData/Android/addressables_content_state.bin` 없음. 기존 산출물은 Standalone(OSX/Linux/Windows)뿐. ⇒ **최초 콘텐츠 빌드는 반드시 full 빌드(BuildPlayerContent)**여야 하고, "Update a Previous Build"는 기준점(baseline)이 생긴 뒤(③a 최초 실행 후)에만 가능.
- `content_state.bin`·`ServerData/`·`Build/`·`Library/`는 전부 **gitignore** — CI가 매번 fresh 빌드, git엔 baseline 없음. baseline은 **S3에 보존**(`s3://lop-client/builds/<sha>/addressables_content_state.bin`).
- 의존 UPM: `Packages/manifest.json`이 `file:../../GameFramework`, `file:../../LeagueOfPhysical-Shared`, `file:../../LeagueOfPhysical-MasterData-Client`를 참조(Packages 기준 2단계 위 = **체크아웃 부모 디렉토리**). Art는 git submodule(`Assets/Art` → `Baeinsoo/LeagueOfPhysical-Art`). **관련 레포 전부 public** → 토큰 없이 plain https 클론 가능(Phase 3와 동일).
- Android 설정: `applicationIdentifier(Android)=com.BAEGames.LeagueOfPhysicalClient`, `bundleVersion=0.1`, `AndroidBundleVersionCode=1`, ARMv7 only(`AndroidTargetArchitectures=1`), **Mono2x**(scriptingBackend 미지정 = 기본), 디버그 서명(`androidUseCustomKeystore=0`).
- Assets/Editor·Assets/Scripts에 asmdef 없음 → `BuildScript.cs`를 `Assets/Editor/`에 두면 `Assembly-CSharp-Editor`로 컴파일되어 Addressables 에디터 어셈블리 자동 참조.
- 기존 스크립트: `Scripts/upload-serverdata-s3.sh`(전체 `ServerData` → `s3://lop-assets/dev` **`--delete`**), `Scripts/upload-apk-s3.sh`(단일 파일 `s3://lop-client/lop.apk`, 끝에 대화형 `read`로 CI 블록). 둘 다 Phase 4 요구(플랫폼 스코프·버전드 레이아웃)와 안 맞아 **재사용하지 않고** 워크플로에 새 업로드 로직을 둔다.

**불변 규칙:**
1. Unity 산출물(APK/ServerData/Library, 수백 MB~GB)은 git에 커밋하지 않는다(이미 gitignore). CI가 매번 fresh 빌드.
2. 콘텐츠 업로드는 **`--delete` 금지(additive sync)**. "Update a Previous Build"는 변경분만 새 번들로 나오고 미변경 번들은 기존 이름을 유지 — `--delete`로 지우면 설치된 앱의 카탈로그가 참조하는 번들이 사라져 깨진다. 고아(orphan) 번들 정리는 별도 과제(범위 밖).
3. APK는 버전드 레이아웃 `s3://lop-client/builds/<sha>/`에 보존하고 `s3://lop-client/builds/latest.json`(sha 포인터)을 갱신. 단일 파일 덮어쓰기(`lop.apk`) 폐지.
4. ③b(콘텐츠)는 ③a(앱)가 최소 1회 실행돼 baseline `content_state.bin`을 남긴 뒤에만 성공한다. baseline 부재 시 명확히 실패시키고 "③a 먼저 실행" 안내.
5. 두 워크플로 모두 `runs-on: [self-hosted, client]` — Client 전용 러너에서만. AWS 키는 env로 주입(launchd 러너는 맥 keychain 접근 불가하나 aws CLI는 env 변수를 직접 읽으므로 무방).
6. Unity는 `-buildTarget Android`로 기동해 활성 타깃을 Android로 고정(런 중 도메인 리로드 회피). 콘텐츠·APK 모두 Android 타깃.

**검증:** 두 워크플로 Actions 콘솔 성공, `s3://lop-client/builds/<sha>/lop.apk` + `addressables_content_state.bin` 존재, `s3://lop-client/builds/latest.json`이 그 sha, `s3://lop-assets/dev/Android/`에 `catalog_*.json`·`*.bundle` 존재, ③b 실행 후 콘텐츠 갱신(카탈로그 hash 변화).

---

### Task 1: Client 전용 2번째 셀프호스트 러너 등록 (맥)

같은 맥에 Client 레포용 러너 인스턴스를 별도로 등록한다. Phase 3의 Server 러너(`~/actions-runner-lop`)와 독립.

**Files:** 없음 (러너 설치 — 맥 로컬 + GitHub 등록)

**Interfaces:**
- Produces: `[self-hosted, client]` 라벨 러너(온라인). Task 5·6 워크플로가 `runs-on: [self-hosted, client]`로 사용.

- [ ] **Step 1: 등록 토큰 발급 + 러너 다운로드 (별도 디렉토리)**

```bash
# Client 레포 등록 토큰 (활성 gh 계정 Baeinsoo가 admin)
TOKEN=$(gh api -X POST repos/Baeinsoo/LeagueOfPhysical-Client/actions/runners/registration-token --jq .token)
echo "token 발급: ${TOKEN:0:8}..."
# Server 러너와 겹치지 않게 새 디렉토리
mkdir -p ~/actions-runner-lop-client && cd ~/actions-runner-lop-client
RUNNER_VER=2.320.0
curl -sLo runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-osx-arm64-${RUNNER_VER}.tar.gz"
tar xzf runner.tar.gz
```
권한 오류면 사용자에게 GitHub UI(Client repo → Settings → Actions → Runners → New self-hosted runner) 위임.

- [ ] **Step 2: 러너 구성 (비대화형, `client` 라벨)**

```bash
cd ~/actions-runner-lop-client
./config.sh --unattended \
  --url https://github.com/Baeinsoo/LeagueOfPhysical-Client \
  --token "$TOKEN" \
  --name lop-mac-runner-client \
  --labels self-hosted,macos,client,unity \
  --work _work
```
Expected: "Runner successfully added" + "Connected to GitHub". (`client` 라벨로 Server 러너와 구분.)

- [ ] **Step 3: launchd 서비스로 상주 실행 (Server 러너와 별개 서비스)**

```bash
cd ~/actions-runner-lop-client
./svc.sh install
./svc.sh start
./svc.sh status
```
Expected: 서비스 실행 중. 서비스명은 러너 이름 기반이라 Server 러너(`lop-mac-runner`)와 충돌하지 않음. (서비스는 로그인 사용자로 돌아 맥의 Unity 라이선스를 그대로 사용.)

- [ ] **Step 4: 러너 온라인 확인**

```bash
gh api repos/Baeinsoo/LeagueOfPhysical-Client/actions/runners --jq '.runners[] | .name + " => " + .status'
```
Expected: `lop-mac-runner-client => online`.

주의(문서화만): Server 러너와 Client 러너가 동시에 각자 Unity batchmode를 띄우면 같은 맥에서 Unity 인스턴스 2개가 경합할 수 있다. 실사용은 수동 버튼이라 실무상 위험 낮음 — 동시에 두 Unity 빌드 버튼을 누르지 않는다. 각 워크플로는 자기 레포 내 `concurrency` 그룹으로 자기끼리는 직렬화된다.

---

### Task 2: 전용 IAM 사용자·정적 키 생성 + Client 레포 시크릿 + 버킷 준비

CI가 세션 만료 없이 S3에 쓸 수 있도록 최소권한 IAM 사용자를 만들고 키를 Client 레포 시크릿으로 등록한다. `lop-client` 버킷이 없으면 생성한다.

**Files:**
- Create(임시, 커밋 안 함): `/private/tmp/.../lop-ci-s3-policy.json` (IAM 정책 문서)

**Interfaces:**
- Produces: Client 레포 시크릿 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Task 5·6 워크플로가 env로 사용. 버킷 `lop-client`(ap-northeast-2) 존재 보장.

- [ ] **Step 1: root aws 세션 재인증 (IAM 생성용)**

IAM 사용자·버킷 생성은 관리자 권한이 필요하다. 맥은 브라우저 `aws login`을 쓰므로 사용자에게 요청:
> 세션에서 `! aws login` 을 실행해 브라우저 인증을 마쳐주세요 (root/admin).

확인:
```bash
aws sts get-caller-identity --output text
```
Expected: 계정 ID·ARN 출력(만료 아님).

- [ ] **Step 2: 최소권한 정책 문서 작성**

`lop-ci-s3-policy.json` (스크래치패드에):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListTargetBuckets",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::lop-assets", "arn:aws:s3:::lop-client"]
    },
    {
      "Sid": "RWObjects",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::lop-assets/*", "arn:aws:s3:::lop-client/*"]
    }
  ]
}
```
(`DeleteObject`는 콘텐츠 additive 정책상 거의 안 쓰지만 잘못된 업로드 정정용으로 포함. 두 버킷 외 접근 불가 = 최소권한.)

- [ ] **Step 3: IAM 사용자 + 인라인 정책 + 액세스 키 생성**

```bash
POLICY_PATH=/private/tmp/claude-501/-Users-insoobae-workspace-LOP/*/scratchpad/lop-ci-s3-policy.json
aws iam create-user --user-name lop-ci-s3 2>&1 | grep -E "UserName|EntityAlreadyExists" || true
aws iam put-user-policy --user-name lop-ci-s3 --policy-name lop-ci-s3-rw --policy-document file://$(ls $POLICY_PATH)
# 액세스 키 발급 (출력은 1회성 — 즉시 시크릿 등록)
aws iam create-access-key --user-name lop-ci-s3 --output json > /tmp/lop-ci-key.json
AKID=$(python3 -c "import json;print(json.load(open('/tmp/lop-ci-key.json'))['AccessKey']['AccessKeyId'])")
SECRET=$(python3 -c "import json;print(json.load(open('/tmp/lop-ci-key.json'))['AccessKey']['SecretAccessKey'])")
echo "AccessKeyId=${AKID:0:6}..."
```
Expected: 사용자 생성(또는 이미 존재), 정책 부착, 키 발급.

- [ ] **Step 4: Client 레포 GitHub Secrets 등록 + 임시 키파일 삭제**

```bash
gh secret set AWS_ACCESS_KEY_ID     --repo Baeinsoo/LeagueOfPhysical-Client --body "$AKID"
gh secret set AWS_SECRET_ACCESS_KEY --repo Baeinsoo/LeagueOfPhysical-Client --body "$SECRET"
rm -f /tmp/lop-ci-key.json
gh secret list --repo Baeinsoo/LeagueOfPhysical-Client
```
Expected: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` 목록에 표시. 평문 키파일 삭제됨.

- [ ] **Step 5: `lop-client` 버킷 존재 보장**

```bash
if aws s3api head-bucket --bucket lop-client 2>/dev/null; then
  echo "lop-client 이미 존재"
else
  aws s3api create-bucket --bucket lop-client --region ap-northeast-2 \
    --create-bucket-configuration LocationConstraint=ap-northeast-2
  echo "lop-client 생성됨"
fi
aws s3api head-bucket --bucket lop-assets 2>/dev/null && echo "lop-assets OK (콘텐츠용, 기존)"
```
Expected: `lop-client` 존재/생성, `lop-assets` 존재 확인. (`lop-client`은 비공개 유지 — APK는 presigned URL로 공유. `lop-assets`는 앱이 익명으로 콘텐츠를 로드하므로 기존 공개 읽기 정책 그대로.)

---

### Task 3: BuildScript.cs 작성 (APK + 콘텐츠 full/update) + 로컬 batchmode 검증

CI가 호출할 `-executeMethod` 진입점 3개를 작성한다. 모두 Android 타깃.

**Files:**
- Create: `LeagueOfPhysical-Client/Assets/Editor/BuildScript.cs`

**Interfaces:**
- Produces:
  - `BuildScript.BuildAndroidContentFull` — Android 어드레서블 full 빌드 → `ServerData/Android/` + `Assets/AddressableAssetsData/Android/addressables_content_state.bin`. (③a·최초 baseline)
  - `BuildScript.BuildAndroidContentUpdate` — 기존 `content_state.bin`(CI가 S3에서 받아 배치) 기준 "Update a Previous Build" → `ServerData/Android/`. (③b)
  - `BuildScript.BuildAndroidApk` — Android APK → `Build/lop.apk`(디버그 서명, 콘텐츠 암시적 재빌드 안 함).
  - Task 5·6 워크플로가 각 메서드를 `-executeMethod`로 호출. content_state 경로는 `Assets/AddressableAssetsData/Android/addressables_content_state.bin` 규약.

- [ ] **Step 1: BuildScript.cs 작성**

`Assets/Editor/BuildScript.cs`:
```csharp
using System.Linq;
using UnityEditor;
using UnityEditor.AddressableAssets;
using UnityEditor.AddressableAssets.Build;
using UnityEditor.AddressableAssets.Settings;
using UnityEngine;

// CI 호출 예: Unity -batchmode -quit -nographics -buildTarget Android -projectPath . \
//   -executeMethod BuildScript.<Method> -logFile -
public static class BuildScript
{
    // ── 어드레서블: full 빌드 (③a / 최초 baseline). ServerData/Android + content_state.bin 생성.
    public static void BuildAndroidContentFull()
    {
        var settings = EnsureSettings();
        AddressableAssetSettings.BuildPlayerContent(out AddressablesPlayerBuildResult result);
        FinishContent(result, "FULL");
    }

    // ── 어드레서블: 증분 빌드 (③b). CI가 S3 baseline을 아래 경로에 미리 배치해야 함.
    public static void BuildAndroidContentUpdate()
    {
        var settings = EnsureSettings();
        var statePath = ContentUpdateScript.GetContentStateDataPath(false); // Assets/AddressableAssetsData/Android/addressables_content_state.bin
        if (!System.IO.File.Exists(statePath))
        {
            Debug.LogError($"content_state 없음: {statePath}. ③a(앱 빌드)를 먼저 실행해 baseline을 생성하세요.");
            EditorApplication.Exit(2);
            return;
        }
        Debug.Log($"content update baseline: {statePath}");
        var result = ContentUpdateScript.BuildContentUpdate(settings, statePath);
        FinishContent(result, "UPDATE");
    }

    // ── APK 빌드 (③a). 디버그 서명(프로젝트 기본). 콘텐츠는 별도 스텝에서 이미 빌드했으므로 재빌드 안 함.
    public static void BuildAndroidApk()
    {
        var settings = EnsureSettings();
        settings.BuildAddressablesWithPlayerBuild =
            AddressableAssetSettings.PlayerBuildOption.DoNotBuildWithPlayer;

        var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
        var options = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = "Build/lop.apk",
            target = BuildTarget.Android,
            targetGroup = BuildTargetGroup.Android,
            options = BuildOptions.None,
        };
        var report = BuildPipeline.BuildPlayer(options);
        var summary = report.summary;
        if (summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded)
        {
            Debug.LogError($"APK build FAILED: {summary.result}, errors={summary.totalErrors}");
            EditorApplication.Exit(1);
            return;
        }
        Debug.Log($"APK OK: {summary.outputPath}, size={summary.totalSize} bytes");
        EditorApplication.Exit(0);
    }

    static AddressableAssetSettings EnsureSettings()
    {
        var settings = AddressableAssetSettingsDefaultObject.Settings;
        if (settings == null)
        {
            Debug.LogError("AddressableAssetSettings를 찾을 수 없음");
            EditorApplication.Exit(1);
        }
        // 활성 프로파일은 프로젝트에 저장된 dev를 사용(원격 경로 = s3://lop-assets/dev/[BuildTarget]).
        Debug.Log($"active profile id: {settings.activeProfileId}");
        return settings;
    }

    static void FinishContent(AddressablesPlayerBuildResult result, string mode)
    {
        if (result != null && !string.IsNullOrEmpty(result.Error))
        {
            Debug.LogError($"Addressables {mode} build FAILED: {result.Error}");
            EditorApplication.Exit(1);
            return;
        }
        Debug.Log($"Addressables {mode} build OK. duration={result?.Duration}s");
        EditorApplication.Exit(0);
    }
}
```

- [ ] **Step 2: 로컬 batchmode로 full 콘텐츠 빌드 검증 (경로·성공 확인)**

CI 전에 맥에서 직접 한 번 돌려 산출 경로·성공을 확인(활성 타깃을 Android로 고정):
```bash
UNITY=/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Client
"$UNITY" -batchmode -quit -nographics -buildTarget Android -projectPath . \
  -executeMethod BuildScript.BuildAndroidContentFull -logFile - 2>&1 | tail -40
ls -la ServerData/Android/ && test -f Assets/AddressableAssetsData/Android/addressables_content_state.bin \
  && echo "CONTENT + STATE OK"
```
Expected: 빌드 성공, `ServerData/Android/`에 `catalog_*.json`·`catalog_*.hash`·`*.bundle`, `Assets/AddressableAssetsData/Android/addressables_content_state.bin` 생성. (컴파일 에러 시: Addressables 에디터 타입 미참조면 `Assets/Editor`에 asmdef가 끼어든 것 — 없어야 정상. `NamedBuildTarget`/API 차이가 있으면 2.9.1 시그니처에 맞춤.)

- [ ] **Step 3: 로컬 APK 빌드 검증**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Client
"$UNITY" -batchmode -quit -nographics -buildTarget Android -projectPath . \
  -executeMethod BuildScript.BuildAndroidApk -logFile - 2>&1 | tail -40
test -f Build/lop.apk && echo "APK OK: $(du -h Build/lop.apk | cut -f1)"
```
Expected: `Build/lop.apk` 생성(디버그 서명). Android SDK/NDK 경로 문제 시 Unity Hub의 Android 모듈 SDK 설정 확인.

- [ ] **Step 4: Commit (산출물은 gitignore라 스크립트만) — 피처 브랜치**

Client CLAUDE.md 규칙: main 직접 커밋 금지, 피처 브랜치 + `--no-ff` 병합.
```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Client
git checkout -b feature/ci-build-scripts
git add Assets/Editor/BuildScript.cs Assets/Editor/BuildScript.cs.meta 2>/dev/null || git add Assets/Editor/BuildScript.cs
git commit -m "feat(build): Android APK/어드레서블 batchmode 빌드 스크립트(CI용)"
git checkout main && git merge --no-ff feature/ci-build-scripts -m "Merge feature/ci-build-scripts"
git push origin main
```
(`.meta`가 없으면 Unity가 생성 후 다시 커밋. `Build/`·`ServerData/`는 gitignore되어 커밋 안 됨.)

---

### Task 4: ③a client-app-deploy 워크플로 (콘텐츠 full → S3, APK → 버전드 S3)

버튼 → Android 콘텐츠 full 빌드 → `s3://lop-assets/dev/Android/` 업로드 → APK 빌드 → `s3://lop-client/builds/<sha>/`에 APK+content_state 보존 → `latest.json` 갱신.

**Files:**
- Create: `LeagueOfPhysical-Client/.github/workflows/client-app-deploy.yml`

**Interfaces:**
- Consumes: 러너(Task 1), AWS 시크릿·버킷(Task 2), BuildScript(Task 3).
- Produces: `s3://lop-client/builds/<sha>/{lop.apk,addressables_content_state.bin}`, `s3://lop-client/builds/latest.json`, `s3://lop-assets/dev/Android/*`. ③b의 baseline 기준점.

- [ ] **Step 1: 워크플로 작성**

`.github/workflows/client-app-deploy.yml`:
```yaml
name: client-app-deploy
on:
  workflow_dispatch:

concurrency:
  group: client-app-deploy
  cancel-in-progress: false

env:
  AWS_DEFAULT_REGION: ap-northeast-2

jobs:
  build-deploy:
    runs-on: [self-hosted, client]      # Client 전용 맥 러너
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive          # Assets/Art (public) 포함

      - name: sha 산출
        id: tag
        run: echo "sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      - name: 의존 UPM 패키지 레포 체크아웃 (file:../../ 형제 위치)
        run: |
          set -e
          cd "$GITHUB_WORKSPACE/.."
          for r in GameFramework LeagueOfPhysical-Shared LeagueOfPhysical-MasterData-Client; do
            if [ -d "$r/.git" ]; then
              git -C "$r" fetch --depth 1 origin && git -C "$r" reset --hard @{u}
            else
              git clone --depth 1 "https://github.com/Baeinsoo/$r" "$r"
            fi
            echo "$r @ $(git -C "$r" rev-parse --short HEAD)"
          done

      - name: 어드레서블 콘텐츠 full 빌드 (Android)
        run: |
          set -eo pipefail
          UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
          if ! "$UNITY" -batchmode -quit -nographics -buildTarget Android -projectPath . \
                -executeMethod BuildScript.BuildAndroidContentFull -logFile - > unity-content.log 2>&1; then
            echo "::error::content build failed"; tail -80 unity-content.log; exit 1
          fi
          tail -15 unity-content.log
          test -f Assets/AddressableAssetsData/Android/addressables_content_state.bin
          ls ServerData/Android

      - name: 콘텐츠 업로드 (additive, --delete 금지)
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          set -e
          aws s3 sync ServerData/Android "s3://lop-assets/dev/Android"
          echo "콘텐츠 업로드 완료: s3://lop-assets/dev/Android/"

      - name: APK 빌드 (Android, 디버그 서명)
        run: |
          set -eo pipefail
          UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
          if ! "$UNITY" -batchmode -quit -nographics -buildTarget Android -projectPath . \
                -executeMethod BuildScript.BuildAndroidApk -logFile - > unity-apk.log 2>&1; then
            echo "::error::APK build failed"; tail -80 unity-apk.log; exit 1
          fi
          tail -15 unity-apk.log
          test -f Build/lop.apk

      - name: APK + content_state 보존 (버전드) + latest 갱신
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          set -e
          SHA="${{ steps.tag.outputs.sha }}"
          DEST="s3://lop-client/builds/$SHA"
          aws s3 cp Build/lop.apk "$DEST/lop.apk"
          aws s3 cp Assets/AddressableAssetsData/Android/addressables_content_state.bin \
            "$DEST/addressables_content_state.bin"
          # latest 포인터 (③b가 읽음)
          printf '{"sha":"%s","apk":"%s/lop.apk","content_state":"%s/addressables_content_state.bin"}\n' \
            "$SHA" "$DEST" "$DEST" > latest.json
          aws s3 cp latest.json "s3://lop-client/builds/latest.json"
          echo "보존: $DEST/ , latest.json -> $SHA"
          # 공유용 presigned URL (7일)
          aws s3 presign "$DEST/lop.apk" --expires-in 604800
```
설명: 콘텐츠→S3(앱이 로드) 후 APK 빌드·보존. `--delete` 없음(불변 규칙 2). git push 없음. AWS 키는 env로만(launchd keychain 우회). presign은 로그에 다운로드 URL을 남김.

- [ ] **Step 2: YAML 검증 + 커밋·push (workflow scope)**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Client
ruby -ryaml -e "YAML.load_file('.github/workflows/client-app-deploy.yml'); puts 'YAML OK'"
git checkout -b feature/ci-app-workflow
git add .github/workflows/client-app-deploy.yml
git commit -m "ci: 클라이언트 앱(APK) 배포 워크플로 (콘텐츠 full + APK 버전드 S3)"
git checkout main && git merge --no-ff feature/ci-app-workflow -m "Merge feature/ci-app-workflow"
git push origin main
```
(Phase 2에서 활성 계정에 workflow scope 부여됨 — 재사용.)

---

### Task 5: ③b content-deploy 워크플로 (baseline 다운로드 → update → S3)

버튼 → S3 `latest.json`의 baseline `content_state.bin` 다운로드 → "Update a Previous Build" 증분 빌드 → `s3://lop-assets/dev/Android/` additive 업로드.

**Files:**
- Create: `LeagueOfPhysical-Client/.github/workflows/content-deploy.yml`

**Interfaces:**
- Consumes: 러너(Task 1), AWS 시크릿(Task 2), BuildScript(Task 3), ③a가 남긴 `s3://lop-client/builds/latest.json`+baseline(Task 4).
- Produces: 갱신된 `s3://lop-assets/dev/Android/`(카탈로그+변경 번들). 설치된 앱과 호환.

- [ ] **Step 1: 워크플로 작성**

`.github/workflows/content-deploy.yml`:
```yaml
name: content-deploy
on:
  workflow_dispatch:

concurrency:
  group: content-deploy
  cancel-in-progress: false

env:
  AWS_DEFAULT_REGION: ap-northeast-2

jobs:
  build-deploy:
    runs-on: [self-hosted, client]
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: 의존 UPM 패키지 레포 체크아웃
        run: |
          set -e
          cd "$GITHUB_WORKSPACE/.."
          for r in GameFramework LeagueOfPhysical-Shared LeagueOfPhysical-MasterData-Client; do
            if [ -d "$r/.git" ]; then
              git -C "$r" fetch --depth 1 origin && git -C "$r" reset --hard @{u}
            else
              git clone --depth 1 "https://github.com/Baeinsoo/$r" "$r"
            fi
          done

      - name: baseline content_state 다운로드 (S3 latest)
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          set -e
          if ! aws s3 cp "s3://lop-client/builds/latest.json" latest.json 2>/dev/null; then
            echo "::error::latest.json 없음 — ③a(client-app-deploy)를 먼저 실행해 baseline을 만드세요."; exit 1
          fi
          STATE_KEY=$(python3 -c "import json;print(json.load(open('latest.json'))['content_state'])")
          echo "baseline: $STATE_KEY"
          mkdir -p Assets/AddressableAssetsData/Android
          aws s3 cp "$STATE_KEY" Assets/AddressableAssetsData/Android/addressables_content_state.bin

      - name: 어드레서블 콘텐츠 update 빌드 (Update a Previous Build)
        run: |
          set -eo pipefail
          UNITY="/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity"
          if ! "$UNITY" -batchmode -quit -nographics -buildTarget Android -projectPath . \
                -executeMethod BuildScript.BuildAndroidContentUpdate -logFile - > unity-content.log 2>&1; then
            echo "::error::content update failed"; tail -80 unity-content.log; exit 1
          fi
          tail -15 unity-content.log
          ls ServerData/Android

      - name: 콘텐츠 업로드 (additive, --delete 금지)
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          set -e
          aws s3 sync ServerData/Android "s3://lop-assets/dev/Android"
          echo "콘텐츠 갱신 완료: s3://lop-assets/dev/Android/"
```
설명: baseline을 규약 경로에 배치 → `BuildContentUpdate`가 그 기준으로 증분 → additive 업로드(미변경 번들 보존, 불변 규칙 2). ③a 미실행 시 명확 실패(불변 규칙 4).

- [ ] **Step 2: YAML 검증 + 커밋·push**

```bash
cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Client
ruby -ryaml -e "YAML.load_file('.github/workflows/content-deploy.yml'); puts 'YAML OK'"
git checkout -b feature/ci-content-workflow
git add .github/workflows/content-deploy.yml
git commit -m "ci: 어드레서블 콘텐츠 배포 워크플로 (Update a Previous Build → S3)"
git checkout main && git merge --no-ff feature/ci-content-workflow -m "Merge feature/ci-content-workflow"
git push origin main
```

---

### Task 6: 첫 실행 + 검증 (③a → baseline 확립 → ③b)

순서 중요: ③a를 먼저 돌려 baseline을 만든 뒤 ③b를 검증한다(불변 규칙 4).

**Files:** 없음 (실행·검증)

- [ ] **Step 1: ③a 앱 워크플로 실행**

```bash
gh workflow run client-app-deploy.yml --repo Baeinsoo/LeagueOfPhysical-Client
sleep 8; RID=$(gh run list --repo Baeinsoo/LeagueOfPhysical-Client --workflow client-app-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId'); echo "run $RID"
gh run watch "$RID" --repo Baeinsoo/LeagueOfPhysical-Client --exit-status --interval 30 || echo "실패 — gh run view $RID --log-failed"
```
Expected: 콘텐츠 full 빌드 → S3 → APK 빌드 → 버전드 보존 성공. (콘텐츠+APK 2회 Unity 빌드라 오래 걸림.)

- [ ] **Step 2: ③a 산출물 S3 검증**

```bash
SHA=$(cd /Users/insoobae/workspace/LOP/LeagueOfPhysical-Client && git rev-parse --short HEAD)
export AWS_DEFAULT_REGION=ap-northeast-2
aws s3 ls "s3://lop-client/builds/$SHA/"                       # lop.apk + addressables_content_state.bin
aws s3 cp "s3://lop-client/builds/latest.json" - | python3 -m json.tool   # sha == $SHA 확인
aws s3 ls "s3://lop-assets/dev/Android/" | grep -E "catalog_|\.bundle" | head
```
Expected: `builds/$SHA/`에 apk+content_state, `latest.json.sha == $SHA`, `dev/Android/`에 catalog·bundle 존재.

- [ ] **Step 3: ③b 콘텐츠 워크플로 실행 + 검증**

```bash
# 갱신 전 카탈로그 hash 기록
export AWS_DEFAULT_REGION=ap-northeast-2
BEFORE=$(aws s3 ls "s3://lop-assets/dev/Android/" | grep 'catalog_.*\.hash' | awk '{print $4}')
gh workflow run content-deploy.yml --repo Baeinsoo/LeagueOfPhysical-Client
sleep 8; RID=$(gh run list --repo Baeinsoo/LeagueOfPhysical-Client --workflow content-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RID" --repo Baeinsoo/LeagueOfPhysical-Client --exit-status --interval 30 || echo "실패 — gh run view $RID --log-failed"
aws s3 ls "s3://lop-assets/dev/Android/" | grep -E "catalog_|\.bundle" | head
```
Expected: ③b 성공(baseline 다운로드 → update 빌드 → additive 업로드). `dev/Android/`에 카탈로그 여전히 존재(미변경 번들 보존됨 = --delete 안 함 검증). 콘텐츠를 실제로 바꾼 경우 catalog hash가 갱신됨.

- [ ] **Step 4: baseline 부재 방어 확인 (선택)**

③a보다 ③b를 먼저 돌리면 실패해야 함(문서화된 방어). 이미 ③a를 돌렸으므로 생략 가능. 확인하려면 `latest.json`을 임시로 다른 이름으로 옮긴 뒤 ③b 실행 → "latest.json 없음" 에러로 실패하는지 보고 원복.

---

### Task 7: 문서 + 미완료 이월 정리

**Files:**
- Modify: `infrastructure/README.md` (또는 `k8s/argocd/README.md`)

- [ ] **Step 1: 문서 갱신**

클라이언트/콘텐츠 배포 흐름 추가:
- ③a `client-app-deploy` 버튼(Client 전용 러너) → 콘텐츠 full → `s3://lop-assets/dev/Android/` + APK → `s3://lop-client/builds/<sha>/` + `latest.json`.
- ③b `content-deploy` 버튼 → `latest.json` baseline → Update a Previous Build → `s3://lop-assets/dev/Android/`(additive).
- Client 러너(`~/actions-runner-lop-client`, `[self-hosted, client]`) 접속·재발급, IAM `lop-ci-s3` 사용자·시크릿, 콘텐츠 additive(--delete 금지)·orphan 정리 미해결 명시.

```bash
cd /Users/insoobae/workspace/LOP/infrastructure
git add -A && git commit -m "docs: Phase 4(클라이언트 앱/콘텐츠 CI) 반영" && git push origin main
```

- [ ] **Step 2: 미완료/이월 사항 명문화 (문서 하단 또는 memory 갱신)**

- **DOCKERHUB_TOKEN + INFRA_REPO_TOKEN rotate** (Phase 2/3 대화 노출 — lop-backend·LeagueOfPhysical-Server 양쪽) — 여전히 미완료.
- orphan 번들 정리(콘텐츠 additive라 미변경/구 번들 누적) — 별도 과제.
- Standalone(에디터/데스크톱 테스트용) 콘텐츠 파이프라인은 Phase 4 범위 밖(수동/UnityMCP 유지) — Phase 4는 Android 콘텐츠만.
- IL2CPP/ARM64(Mono2x·ARMv7 유지), 릴리스 키스토어·스토어 배포 — 범위 밖.
- db-migrate 이미지 슬림화, 앱 resource limits/probes/HA(Phase 1/2 이월) — 여전히 미해결.

---

## 완료 기준 (Phase 4 검증 = 설계문서 검증 5)

1. Client 전용 러너(`[self-hosted, client]`) 온라인
2. `BuildScript`로 batchmode Android 콘텐츠(full/update) + APK 빌드 성공(로컬 + CI)
3. `client-app-deploy` 버튼 → 콘텐츠 `s3://lop-assets/dev/Android/` + APK `s3://lop-client/builds/<sha>/` + `latest.json` 갱신
4. `content-deploy` 버튼 → baseline 기준 Update a Previous Build → 콘텐츠 additive 갱신(설계문서 검증 5: 앱 재설치 없이 어드레서블 갱신)
5. 두 파이프라인이 서로 독립(각자 버튼), git/ArgoCD 무관, AWS 정적 키로만 동작

## 의도적으로 Phase 4에서 제외

- 실기기 설치·구동 E2E (APK 다운로드→설치→S3 콘텐츠 로드) — 검증은 S3 산출물까지.
- 릴리스 키스토어 서명·Play 스토어/스토어 배포 — 디버그 서명 유지.
- IL2CPP·ARM64 (현재 Mono2x·ARMv7 유지) — 스토어 요건 생길 때.
- orphan 번들 정리, stage/prod 콘텐츠 프로파일 전환 자동화, Standalone 콘텐츠 CI.
- push 자동 트리거 — 버튼만.
