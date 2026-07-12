# 게임서버 하드닝 — IL2CPP + 멀티아치(amd64/arm64) + getPublicIP 주입

**Date:** 2026-07-12
**Related:** [배포 시스템 설계](2026-07-05-deployment-system-design.md) · [Phase 3 게임서버 CI plan](../plans/2026-07-06-phase3-unity-gameserver.md) · 프로젝트 메모리 `deployment-system-project`

## Goal

Phase 3에서 이월한 게임서버 3항목을 하드닝해, **로컬 arm64 클러스터(docker-desktop)에서 게임서버 pod를 실제로 기동**할 수 있게 한다(Phase 3가 의도적으로 제외했던 "pod 기동"을 닫음):

1. **IL2CPP 복귀** — 현재 Mono2x 백엔드 → IL2CPP (성능, 프로덕션 표준)
2. **멀티아치** — 현재 amd64 단일 → amd64 + arm64 (로컬 arm64 클러스터 네이티브 실행)
3. **getPublicIP 하드코딩 해소** — `room.service.ts`의 `'localhost'` 하드코딩 → ConfigMap/env 주입

## 배경 / 현재 상태

Phase 3(게임서버 CI)는 이미지 빌드·배선까지 검증하고 **pod 실제 기동은 제외**했다. 그 이월 항목이 이 세 가지다. 각 항목의 현재 코드:

- **BuildScript** (`LeagueOfPhysical-Server/Assets/Scripts/Editor/BuildScript.cs`): `PlayerSettings.SetScriptingBackend(NamedBuildTarget.Server, ScriptingImplementation.Mono2x)`. IL2CPP는 Phase 3에서 "Unable to find Linux Sysroot"로 실패해 Mono로 후퇴했었다.
- **Dockerfile** (`LeagueOfPhysical-Server/GameServer/Dockerfile`): `ubuntu:20.04`, `COPY Build/ /app/`, amd64 단일.
- **워크플로** (`LeagueOfPhysical-Server/.github/workflows/gameserver-deploy.yml`): `docker build --platform linux/amd64` 단일 아치 → `re5nardo/game-server:<sha>` push → infra `game-server-config` ConfigMap의 `GAME_SERVER_IMAGE` sed-bump.
- **room-server** (`lop-backend/apps/room-server/src/services/room.service.ts:179`): `const ip = /*await k8sUtils.getPublicIP(...)*/'localhost';` — 매치 pod의 접속 IP를 `'localhost'`로 하드코딩. 클라가 이 `ip:nodePort`로 게임서버 pod에 접속.
- **로컬 클러스터**: docker-desktop, **arm64 단일노드**(192.168.65.3 internal, external IP 없음). amd64 이미지는 arm64에서 에뮬레이션 없이 못 뜬다.

### 실측 결과 (2026-07-12) — IL2CPP는 이미 가능

Phase 3의 sysroot 블로커가 **이미 해소됐음을 실측으로 확인**:
- Unity 6000.3.16f1의 Linux 서버 빌드 variation에 `linux64_server_*_il2cpp`(amd64)와 `linuxarm64_server_*_il2cpp`(arm64)가 존재. **arm64 Linux 서버는 IL2CPP variation만 있고 Mono가 없다** → arm64는 IL2CPP 강제.
- Server manifest에 `com.unity.sdk.linux-x86_64`·`com.unity.sdk.linux-arm64`(1.1.0) 패키지가 추가돼 있음(미커밋 WIP). 이 SDK 패키지가 IL2CPP 크로스컴파일 sysroot를 제공.
- **BuildScript를 IL2CPP로 바꿔 로컬 batchmode 빌드 → `Build OK`, `GameAssembly.so` 생성, `lop-server.x86_64` 산출.** "Unable to find Linux Sysroot" 에러 없음. ⇒ IL2CPP amd64는 확정.
- Linux IL2CPP 툴체인(llvm-9.0.1, 389MB)이 `~/Library/Unity/cache/sysroots/darwin-arm64-linux-x86_64`에 캐시됨. 단 **arm64 타깃 sysroot는 캐시에 없음**(`linux-x86_64`만) → arm64 빌드는 arm64 sysroot 다운로드가 선행돼야 함(미검증 리스크).

## 설계

세 부분(A/B/C)으로 나눈다. A(IL2CPP)는 검증됨, B(멀티아치 arm64)는 sysroot 다운로드가 미검증이라 **plan 첫 태스크로 실측 후 진행**, C(getPublicIP)는 단순 배선.

### A. IL2CPP 전환 (검증됨)

- **manifest**: Server `Packages/manifest.json`의 `com.unity.sdk.linux-arm64`·`com.unity.sdk.linux-x86_64`·`com.unity.toolchain.macos-arm64-linux`(현재 WIP) 커밋. 이 패키지들이 IL2CPP Linux sysroot를 제공.
- **BuildScript**: `ScriptingImplementation.Mono2x` → `ScriptingImplementation.IL2CPP`. 관련 주석(sysroot 부재 언급) 갱신.
- **근거**: arm64가 IL2CPP만 지원하므로 멀티아치를 하려면 IL2CPP가 필수이기도 하다.

### B. 멀티아치 (amd64 + arm64)

Unity는 한 번 빌드에 한 아키텍처만 산출한다. 따라서 **아치별로 Unity를 2회 빌드**하고, 두 이미지를 **docker 멀티아치 매니페스트**로 합친다.

**BuildScript 파라미터화**: 아키텍처를 인자/env로 받아 `x86_64` / `arm64`를 선택.
- 아키텍처 선택 API: Unity 6의 `PlayerSettings`/Linux 확장 아키텍처 설정(ProjectSettings의 `platformArchitecture` 필드에 저장; Linux 확장에 `GetArchitectureFromString`/`SetArchitecture` 계열 존재). **정확한 시그니처는 plan 1번 태스크에서 확정·테스트**.
- 산출 경로는 아치별로 분리(예: `GameServer/Build-x86_64/`, `GameServer/Build-arm64/`)해 두 이미지 빌드에 각각 사용.

**docker 멀티아치**: 두 아치의 서버 바이너리가 서로 달라 buildx 단일 컨텍스트로는 안 됨. 아치별로 이미지를 빌드·push한 뒤 `docker manifest`로 합친다:
```
docker build --platform linux/amd64 -t re5nardo/game-server:<sha>-amd64 <ctx-amd64>; docker push …
docker build --platform linux/arm64 -t re5nardo/game-server:<sha>-arm64 <ctx-arm64>; docker push …
docker manifest create re5nardo/game-server:<sha> \
  --amend re5nardo/game-server:<sha>-amd64 --amend re5nardo/game-server:<sha>-arm64
docker manifest push re5nardo/game-server:<sha>
```
→ `re5nardo/game-server:<sha>`가 멀티아치 매니페스트가 되어, arm64 노드는 arm64 이미지를, amd64 노드는 amd64 이미지를 자동 pull.

**Dockerfile**: 베이스 이미지가 멀티아치인지 확인(`ubuntu:20.04`은 amd64+arm64 지원 O). `COPY Build/`가 아치별 컨텍스트를 받도록 정합.

**arm64 리스크(plan 1번 태스크로 선검증)**: arm64 타깃 sysroot가 캐시에 없어 다운로드가 필요. `com.unity.sdk.linux-arm64` 패키지가 자동으로 받아오는지, 아니면 Unity Hub 모듈 설치가 추가로 필요한지 로컬 arm64 IL2CPP 빌드로 먼저 실측한다. 실패 시 대안(Hub 모듈 설치)까지 이 태스크에서 확정.

### C. getPublicIP 주입

- **room-server** (`room.service.ts:179`): `'localhost'` 하드코딩 → `process.env.GAME_SERVER_PUBLIC_IP || 'localhost'`. (fallback으로 localhost 유지 — 로컬 docker-desktop은 NodePort가 localhost에 노출돼 실제 동작.) 다른 로직·포트·env 불변.
- **infra**: `game-server-config` ConfigMap(`k8s/apps/backend/game-server-config/configmap.yaml`)에 `GAME_SERVER_PUBLIC_IP: localhost` 추가. room-server는 이미 이 ConfigMap을 `envFrom`으로 받으므로(Phase 3 배선) 배선 추가 불필요, 키만 추가.
- 클라우드 이전 시 이 값을 노드/LB IP로 ConfigMap에서 바꾸면 됨(코드·이미지 재빌드 불필요).

## 데이터 흐름 (멀티아치 배포 + pod 기동)

```
gameserver-deploy 버튼
  → (러너) Unity IL2CPP 빌드 ×2 (amd64, arm64)
  → docker 이미지 ×2 push + manifest 합쳐 re5nardo/game-server:<sha> (멀티아치)
  → infra game-server-config ConfigMap GAME_SERVER_IMAGE bump → ArgoCD sync

매치 생성 (room-server)
  → GAME_SERVER_IMAGE(멀티아치)로 게임서버 pod 생성 → arm64 노드가 arm64 이미지 pull → pod Running
  → NodePort Service 생성, room.ip = GAME_SERVER_PUBLIC_IP(=localhost), room.port = nodePort
  → 클라가 localhost:nodePort로 게임서버 pod 접속
```

## 검증 계획 (완료의 정의)

1. `gameserver-deploy` 버튼 → `re5nardo/game-server:<sha>`가 **멀티아치 매니페스트**(amd64+arm64)로 push (`docker manifest inspect`로 2아치 확인)
2. IL2CPP 산출 확인(GameAssembly.so 기반 이미지)
3. infra ConfigMap `GAME_SERVER_IMAGE` bump + `GAME_SERVER_PUBLIC_IP` 존재, ArgoCD Synced
4. **매치 생성 → 게임서버 pod가 arm64 노드에서 Running**(Phase 3가 미룬 pod 기동)
5. room-server가 `GAME_SERVER_PUBLIC_IP` env로 room.ip 설정, 클라가 그 ip:nodePort로 접속 성공

## Out of Scope

- **실제 게임플레이 검증**(매칭 로비→게임→종료 풀 루프)은 pod 기동·접속 확인까지가 이 작업 범위. 게임 내용 검증은 별개.
- **클라우드 이전**(EKS/GKE, 실제 공인 IP/LB) — `GAME_SERVER_PUBLIC_IP`를 ConfigMap에서 바꾸면 확장되게 설계하되, 실제 클라우드 배포는 범위 밖.
- **Docker Desktop 상시 실행 보장** — 러너 docker push는 Docker 데몬 필요(현재 수동). 데몬 자동 기동은 범위 밖.
- **getPublicIP의 k8s downward API/노드 IP 자동 조회** — 지금은 ConfigMap 정적값으로 충분. 자동 조회는 클라우드 과제.

## 산업 표준 매핑

- **멀티아치 이미지 = docker manifest list (OCI image index)**: 아치별 이미지를 하나의 태그로 묶는 표준 방식(docker/OCI). 서로 다른 빌드 산출물을 합칠 땐 buildx 단일 컨텍스트가 아니라 `docker manifest create/push`가 정석.
- **게임서버 public IP 주입 = 환경변수/ConfigMap 12-factor 설정**: 접속 엔드포인트를 코드가 아닌 환경설정으로(Twelve-Factor III. Config). Agones 등 게임서버 오케스트레이터도 외부 접속 주소를 환경/상태로 주입.

## 진행

- [x] 브레인스토밍 합의 (IL2CPP 검증, 멀티아치, getPublicIP ConfigMap)
- [x] IL2CPP amd64 실측 성공
- [x] 이 spec 작성
- [ ] spec self-review
- [ ] 사용자 spec 리뷰
- [ ] `writing-plans`로 구현 plan (arm64 sysroot 실측을 1번 태스크로)
