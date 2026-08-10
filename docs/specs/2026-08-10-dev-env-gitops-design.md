# dev 환경(iwinv) GitOps 전환 설계

- 날짜: 2026-08-10
- 상태: 확정 (구현 전)
- 범위: infrastructure 매니페스트 환경 분리, iwinv k3s에 ArgoCD 도입, 배포 CI 2종의 환경 선택

## 1. 배경 — 지금 무엇이 문제인가

iwinv(공인 IP `115.68.178.46`)의 단일노드 k3s에 백엔드 풀스택이 **라이브로 떠 있지만**, 그곳에 배포한 방식은
GitOps가 아니라 **수동**이었다 (2026-07-25).

```
로컬 infrastructure/k8s/  ──rsync──▶  서버 /root/lop-infra/k8s/
                                          │  sed 로 GAME_SERVER_PUBLIC_IP=115.68.178.46 덮어쓰기
                                          ▼
                                      kubectl apply -k
```

그래서 다음이 참이다:

- iwinv 클러스터에는 **ArgoCD가 설치돼 있지 않다.**
- iwinv 전용 값(공인 IP)은 서버에서만 바뀌었고 **레포에 커밋된 적이 없다.**
- 이미지가 SHA 태그가 아니라 `re5nardo/*:latest`다.
- CI(`backend-deploy` / `gameserver-deploy`)가 태그를 bump해도 **iwinv에는 아무것도 내려가지 않는다.**
- iwinv의 매니페스트는 7/25 스냅샷에서 멈춰 있다.

한편 로컬 클러스터(kind-lop)는 ArgoCD app-of-apps로 잘 돌고 있다. 즉 자동화가 **한쪽에만** 있다.

### 왜 지금 하는가

`infrastructure/k8s/`는 **환경 구분이 없는 매니페스트 한 벌**이고, 그 한 벌이 로컬 kind에 맞춰져 있다
(`game-server-config`의 `GAME_SERVER_PUBLIC_IP: 127.0.0.1`). iwinv ArgoCD가 같은 경로를 바라보게 하면
iwinv도 클라에게 `127.0.0.1`을 알려주게 된다. 그래서 이 작업의 본질은 "ArgoCD 설치"가 아니라
**환경 분리**다.

환경 간 실제 차이는 지금 **두 가지뿐**이라 옮기는 비용이 가장 싼 시점이다:

| 값 | local | dev(iwinv) |
|---|---|---|
| `GAME_SERVER_PUBLIC_IP` | `127.0.0.1` | `115.68.178.46` |
| 이미지 태그 | 환경별 독립 | 환경별 독립 |

스토리지클래스는 어디에도 박혀 있지 않고(클러스터 기본값 사용), ingress-nginx 설치는 양쪽 다 GitOps 밖
부트스트랩이며, Ingress 리소스 자체는 동일하다.

## 2. 결정 사항

| 항목 | 결정 | 근거 |
|---|---|---|
| 환경 구성 | local + dev 둘 다 유지 | 로컬은 개발용, iwinv는 클라가 붙는 공용 dev |
| ArgoCD 배치 | **클러스터마다 자체 ArgoCD** (허브-스포크 아님) | 맥이 꺼져 있어도 iwinv가 스스로 동기화해야 함 |
| 매니페스트 구조 | Kustomize `base/` + `envs/<env>/` | 공식 권장 구조. 차이가 한 파일에 모이고 `kustomize build`로 재현 가능 |
| 배포 범위 결정 | 배포 버튼의 `environment` 입력 (`local`/`dev`/`both`), 기본값 `local` | 환경 2개·1인 개발이라 자동+승격은 오버킬(YAGNI). 기본값은 안전한 쪽 |
| platform 오버레이 | **만들지 않음** — 양쪽이 `base/platform`을 직접 참조 | 현재 차이가 0. 필요해지면 그때 추가 |
| 시크릿 | iwinv에서 1회 수기 생성 (로컬과 동일) | 레포가 public이라 커밋 불가. SealedSecrets는 운영 단계 과제 |
| ArgoCD UI 노출 | 노출하지 않음. SSH 터널 + port-forward | 공인 IP에 admin 로그인 화면을 띄우지 않는다 |
| ArgoCD 버전 | v2.13.2 (로컬과 동일) | 두 클러스터 동작 차이를 만들지 않음 |

### 산업 표준 매핑

- **`base/` + `overlays|envs/<env>/`** — Kustomize 공식 권장 레이아웃. ArgoCD도 환경당 Application 하나를
  전제로 설계돼 있다.
- **클러스터별 ArgoCD 설치** — 단일 ArgoCD가 여러 클러스터를 관리하는 허브-스포크도 표준이지만, 허브가
  꺼지면 스포크가 동기화를 멈춘다. 관리 머신이 개인 노트북일 때는 클러스터별 설치가 맞는 선택이다.
- **배포 대상 환경 선택** — GitHub Actions `workflow_dispatch` 입력으로 환경을 고르는 방식은 소규모 팀의
  일반적 관행이다. 더 엄밀한 GitOps 정석은 "가장 낮은 환경 자동 + 위는 승격(promotion)"이며(Argo 진영의
  Kargo 등), 환경이 3개 이상이고 릴리스 게이트가 생길 때 값을 한다. 그때는 `envs/` 구조를 그대로 두고
  CI만 바꾸면 된다.
- 참고: 업계에서 GitOps 대상은 보통 dev/staging/prod 같은 **공유 클러스터**이고 개발자 개인 머신의
  클러스터는 대상이 아니다. 이 매핑에서 **iwinv = dev(표준 위치)**, **로컬 kind = 개발자 워크스테이션**이다.
  로컬을 GitOps에 두는 것은 이미 동작하는 자동화를 버리지 않기 위한 선택이며, 표준 이탈이 아니라 추가다.

## 3. 레포 구조

```
k8s/
├── base/
│   ├── platform/            # postgres, redis, ingress, rbac  (기존 k8s/platform 이동)
│   │   └── kustomization.yaml
│   └── backend/             # lobby, matchmaking, room, db-migrate  (기존 k8s/apps/backend 이동)
│       └── kustomization.yaml
├── envs/
│   ├── local/backend/
│   │   ├── kustomization.yaml
│   │   └── game-server-config.env
│   └── dev/backend/
│       ├── kustomization.yaml
│       └── game-server-config.env
├── argocd/
│   ├── install/README.md    # 공통 설치 절차 (클러스터별 주석)
│   └── envs/
│       ├── local/{root-app.yaml, apps/{platform,backend}.yaml}
│       └── dev/{root-app.yaml, apps/{platform,backend}.yaml}
└── local-k8s/               # kind 클러스터 부트스트랩 (변경 없음)
```

**base에서 제거되는 것**: 각 앱 kustomization의 `images:` 블록, `game-server-config` ConfigMap 리소스.
둘 다 환경별 값이라 `envs/`로 내려간다.

### `envs/<env>/backend/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - ../../../base/backend
images:                                   # CI(backend-deploy)가 이 블록을 bump
  - name: re5nardo/lobby-server
    newTag: <sha>
  - name: re5nardo/matchmaking-server
    newTag: <sha>
  - name: re5nardo/room-server
    newTag: <sha>
  - name: re5nardo/lop-db-migrate
    newTag: <sha>
configMapGenerator:
  - name: game-server-config
    envs:
      - game-server-config.env
```

`images:` 블록은 사람이 손으로 쓰지 않는다 — `kustomize edit set image`가 쓰고 갱신한다
(`newName` + `newTag` 형태로 기록된다).

### `envs/<env>/backend/game-server-config.env`

환경마다 같은 두 키를 갖고 값만 다르다.

```properties
# envs/local/backend/game-server-config.env
GAME_SERVER_IMAGE=re5nardo/game-server:<sha>
GAME_SERVER_PUBLIC_IP=127.0.0.1
```

```properties
# envs/dev/backend/game-server-config.env
GAME_SERVER_IMAGE=re5nardo/game-server:<sha>
GAME_SERVER_PUBLIC_IP=115.68.178.46
```

`GAME_SERVER_PUBLIC_IP`가 `localhost`가 아니라 IPv4 리터럴이어야 하는 이유(Windows IPv6 해석 문제)는
기존 ConfigMap 주석에 있다 — 이동 시 그 주석을 `.env` 파일로 함께 옮긴다.

## 4. 곁들여 고치는 것 — ConfigMap 변경이 파드를 재시작시키지 않는 문제

**현상.** `GAME_SERVER_IMAGE`는 ConfigMap 값이고 room-server는 `envFrom`으로 읽는다. Kubernetes는
`envFrom`으로 주입된 값을 핫리로드하지 않으므로 **ConfigMap만 바뀌면 파드는 옛 값을 계속 쓴다.**
지금까지는 사람이 `kubectl rollout restart deploy/room-server`를 치거나, `backend-deploy`를 뒤에 돌려
파드가 우연히 재시작되는 것에 의존해 왔다("gameserver-deploy 먼저, backend-deploy 나중에" 관행).

**왜 지금 고쳐야 하나.** iwinv에는 그 수동 개입을 할 사람이 없다. GitOps로 전환하면서 이 구멍을 남기면
"ArgoCD는 Synced인데 게임서버는 옛 이미지로 뜬다"는 조용한 실패가 된다.

**해법.** ConfigMap을 kustomize `configMapGenerator`로 만든다. 생성된 이름에 내용 해시가 붙고
(`game-server-config-7t2k9bd4f5`), kustomize가 room-server 디플로이먼트의 `envFrom` 참조도 같은 이름으로
고쳐준다. 따라서 **값이 바뀌면 → 이름이 바뀌고 → 디플로이먼트 spec이 바뀌고 → 파드가 롤링 재시작된다.**

부수 효과:

- CI의 `sed` 대상이 YAML이 아니라 평범한 `KEY=value` 파일이 되어 정규식이 단순·안전해진다.
- 이름이 매번 바뀌므로 옛 ConfigMap이 남는데, ArgoCD가 자기가 만든 리소스로 추적하므로 `prune: true`가
  정리한다.
- room-server는 이 ConfigMap을 `envFrom`으로만 소비한다(코드가 이름을 문자열로 참조하지 않는다). 따라서
  이름 변경으로 깨질 참조가 없다.

## 5. ArgoCD 배치

두 클러스터가 각각 자기 ArgoCD를 갖는다. Application 이름(`platform`, `backend`)은 두 환경에서 동일하고,
`spec.source.path`만 다르다.

| | 로컬 (kind-lop) | iwinv (k3s) |
|---|---|---|
| root-app이 보는 경로 | `k8s/argocd/envs/local/apps` | `k8s/argocd/envs/dev/apps` |
| `platform` App (sync-wave 0) | `k8s/base/platform` | `k8s/base/platform` |
| `backend` App (sync-wave 1) | `k8s/envs/local/backend` | `k8s/envs/dev/backend` |
| syncPolicy | `automated{prune,selfHeal}`, `targetRevision: main` | 동일 |

- infra 레포가 **public**이라 iwinv ArgoCD에 깃 자격증명이 필요 없다. 폴링(기본 3분)으로 충분하며
  웹훅은 만들지 않는다(공개 엔드포인트가 필요해 이득 대비 비용이 크다).
- **UI를 인터넷에 노출하지 않는다.** iwinv ArgoCD 접근은 `ssh -L 8080:localhost:8080` 터널 위에서
  `kubectl port-forward -n argocd svc/argocd-server 8080:443`.
- **자원**: ArgoCD 비-HA 7개 파드가 2c/8GB 박스에 추가된다. 게임서버 파드까지 뜨는 곳이라, 압박이
  관측되면 `argocd-dex-server`(외부 IdP용)와 `argocd-notifications-controller`를 0으로 스케일해 줄인다 —
  admin 로컬 계정 로그인은 dex 없이 동작한다.

### 이름 유지 — 캐스케이드 삭제 주의

이행 시 Application 이름을 바꾸면 ArgoCD가 옛 Application을 지우면서 **딸린 워크로드까지 캐스케이드
삭제**한다. 이름은 그대로 두고 `path`만 바꾸는 in-place 업데이트로 진행한다. root-app 자체는 아무도
관리하지 않는 부트스트랩 리소스이므로 `kubectl apply`로 갱신한다.

## 6. CI 변경

두 워크플로우에 `environment` 입력(`local` / `dev` / `both`, 기본값 `local`)을 추가한다.

### `backend-deploy` (lop-backend)

태그 bump 대상이 앱별 3개 폴더에서 환경 폴더 1개로 바뀐다 — 지금보다 단순해진다.

```bash
# 전: 앱마다 다른 디렉터리
#     cd k8s/apps/backend/lobby-server && kustomize edit set image ...
# 후: 환경 디렉터리 하나에서 앱 루프
for env in "${envs[@]}"; do
  ( cd "k8s/envs/$env/backend" \
    && for app in "${targets[@]}"; do kustomize edit set image "${IMG[$app]}=${IMG[$app]}:${SHA}"; done )
done
```

커밋 메시지에 환경을 남긴다: `ci(deploy): bump backend image tags (dev) -> <sha>`.

### `gameserver-deploy` (LeagueOfPhysical-Server)

`sed` 대상 경로만 바뀐다.

```
전: k8s/apps/backend/game-server-config/configmap.yaml   (YAML 라인 치환)
후: k8s/envs/<env>/backend/game-server-config.env        (KEY=value 치환)
```

`both`면 두 파일 모두 치환한다. 커밋 메시지: `ci(gameserver): bump GAME_SERVER_IMAGE (dev) -> <sha>`.

## 7. 이행 절차

### 1단계 — 레포 재구성 (로컬 클러스터로 검증)

1. `git mv k8s/platform k8s/base/platform`, `git mv k8s/apps/backend k8s/base/backend`
2. base에서 `images:` 블록과 `game-server-config` ConfigMap 리소스 제거
3. `envs/{local,dev}/backend/` 생성 — **현재 값 그대로 이식**
   (local `127.0.0.1`, dev `115.68.178.46`, 태그는 현재 커밋의 SHA 복사)
4. **렌더 diff 검증**: 재구성 전후 `kustomize build` 결과를 비교.
   ConfigMap 이름의 해시 접미사(4절에서 의도한 변화) 말고 다른 차이가 나오면 이식이 틀린 것이다.
5. `k8s/argocd/envs/local/` 생성 → root-app을 새 경로로 `kubectl apply` (Application 이름 유지)
   → 로컬 ArgoCD `Synced`/`Healthy` 확인
6. CI 두 워크플로우 수정 → `environment=local`로 1회 배포해 파이프라인 확인

### 2단계 — iwinv에 ArgoCD 도입

7. **현황 점검** (SSH): 현재 떠 있는 워크로드, 남아있는 mongodb 잔재, 시크릿 유무
8. ArgoCD v2.13.2 설치 (`namespace argocd`)
9. **Sync 이전에** 시크릿 2종 수기 생성 — `auth-secret`, `internal-api-secret`
   (순서를 어기면 lobby/matchmaking이 크래시루프)
10. `k8s/argocd/envs/dev/root-app.yaml` apply → platform/backend Sync
11. **잔재 정리**: ArgoCD가 만들지 않은 옛 리소스(mongodb 등)는 추적 대상이 아니라 `prune`으로 지워지지
    않는다. 수동 삭제한다.

## 8. 리스크

- **iwinv는 7/25 스냅샷 + `:latest` 상태다.** 전환하면 그동안의 infra 변경(내부 키 배선, `/internal`
  차단, matchmaking-director 추가, mongodb 제거)이 한꺼번에 적용되고 이미지도 SHA 태그로 롤링된다.
  짧은 다운타임이 발생한다 — dev 환경이라 허용한다.
- **시크릿 순서.** 위 9번을 10번보다 먼저 하지 않으면 크래시루프를 보게 된다.
- **게임서버 첫 pull과 heartbeat.** 이미지 pull이 heartbeat 임계(10초)를 넘기면 부팅 전에 파드가
  회수된다. 첫 E2E 전에 `crictl pull`로 캐시한다.
- **캐스케이드 삭제.** 5절의 Application 이름 유지 규칙을 어기면 워크로드가 지워진다.

## 9. 성공 기준

- 두 클러스터의 ArgoCD가 모두 `Synced` / `Healthy`
- `curl http://115.68.178.46:31000/{lobby,matchmaking,room}/` → 200 유지
- **게임서버 태그만 바꾼 커밋 → iwinv room-server 파드가 자동 재시작**되고 새 값을 들고 있음 (4절 검증)
- E2E: Match INSERT → 게임서버 파드 스폰 + heartbeat 정상 (기존 `/root/e2e.sh` 절차)
- 롤백: infra 커밋 revert → 폴링 주기(약 3분) 내 이전 상태 복귀

## 10. 범위 밖

- SealedSecrets / External Secrets / SOPS 도입 — 운영 환경 단계 과제. 지금은 수기 부트스트랩 유지
- 자동 배포 + 승격(promotion) 워크플로우 — 환경이 3개 이상이 될 때
- ArgoCD 웹훅, SSO, HA 구성
- 클라이언트 앱/콘텐츠(Addressables) 파이프라인 — 이 작업과 무관
- `postgres-secret.yaml`이 평문으로 커밋돼 있는 기존 부채 — 별도 과제
