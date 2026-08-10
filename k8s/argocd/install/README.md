# ArgoCD Install

## Version
- ArgoCD **v2.13.2** (official upstream manifest, non-HA)
- Namespace: `argocd` (양쪽 클러스터 공통)

## 클러스터

이 레포의 ArgoCD는 클러스터마다 따로 설치한다 (허브-스포크 구조가 아니다) — 각 클러스터의 ArgoCD가 같은
public 레포(`https://github.com/Baeinsoo/infrastructure`)의 **자기 환경 경로만** 본다.

| 환경 | 클러스터 | 접속 | root-app 경로 |
|---|---|---|---|
| local | kind (컨텍스트 `kind-lop`) | `kubectl config use-context kind-lop` | `k8s/argocd/envs/local/root-app.yaml` |
| dev | iwinv k3s, 단일 노드 (`115.68.178.46`) | `ssh -i ~/.ssh/iwinv_lop root@115.68.178.46` — 로컬에 별도 kubectl 컨텍스트를 등록하지 않고, SSH 세션 안에서 kubectl을 그대로 실행한다 | `k8s/argocd/envs/dev/root-app.yaml` |

아래 설치 절차는 두 클러스터 모두 동일하다 — local은 위 `kubectl config use-context`로 대상을 고정한
뒤, dev는 SSH 세션 안에서 그대로 실행하면 된다.

## Install

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
```

## Wait for readiness

```bash
kubectl wait --for=condition=available --timeout=300s deployment -n argocd \
  argocd-server argocd-repo-server argocd-applicationset-controller
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl get pods -n argocd
```

All 7 pods should reach `Running`:
`argocd-application-controller-0`, `argocd-applicationset-controller`,
`argocd-dex-server`, `argocd-notifications-controller`, `argocd-redis`,
`argocd-repo-server`, `argocd-server`.

> **메모리가 빠듯한 클러스터(예: iwinv 단일 노드)**에서는 로그인에 쓰지 않는 두 컴포넌트를 0으로
> 스케일해 여유를 확보할 수 있다: `argocd-dex-server`, `argocd-notifications-controller`.
> iwinv 설치 시점(2026-08-10) 실측: `free -m` 기준 총 7941MB 중 available 6497MB — ArgoCD(약 1GB)
> 대비 여유가 충분해 **스케일 다운하지 않았다**. 7개 파드 모두 기본 replica로 Running 확인.

## Secrets 부트스트랩 (Sync 이전에 반드시)

`k8s/base/backend/*`의 일부 Deployment(`lobby-server`, `matchmaking-server`, `room-server` 등)는
아래 두 Secret을 **ArgoCD가 관리하지 않는 사전 존재 리소스**로 참조한다. root-app을 등록(Task 7)하기
전에 대상 클러스터에 반드시 먼저 만들어 둔다 — 없으면 Pod가 `CreateContainerConfigError`로 뜬다.

| Secret | Key | 용도 |
|---|---|---|
| `auth-secret` | `AUTH_JWT_SECRET` | JWT 서명키 |
| `internal-api-secret` | `INTERNAL_API_KEY` | 내부 API 조회키 |

**반드시 서로 다른 Secret으로 분리한다** — 서명키와 조회키를 합치면 조회키만 필요한 게임서버 파드에도
토큰 위조가 가능한 서명키가 함께 실리게 된다.

```bash
kubectl get secret auth-secret >/dev/null 2>&1 || \
  kubectl create secret generic auth-secret \
    --from-literal=AUTH_JWT_SECRET="$(openssl rand -base64 32)"
kubectl get secret internal-api-secret >/dev/null 2>&1 || \
  kubectl create secret generic internal-api-secret \
    --from-literal=INTERNAL_API_KEY="$(openssl rand -base64 32)"
kubectl get secret
```

- 값은 대상 호스트에서 `openssl rand -base64 32`로 즉석 생성한다 — 어디에도 커밋하거나 echo하지 않는다.
- **이미 존재하면 건드리지 않는다** — 로테이션하지 않는다. 기존 워크로드가 그 값을 쓰고 있을 수 있다.
- 두 Secret 모두 `default` 네임스페이스 (백엔드 워크로드와 동일 네임스페이스).

## Access

- **local**: `argocd-server`는 ClusterIP다. 포트포워드로 접근한다.
  ```bash
  kubectl port-forward -n argocd svc/argocd-server 8080:443
  ```
  이후 https://localhost:8080 (self-signed 인증서 경고는 무시) 또는 헬스체크:
  ```bash
  curl -sk https://localhost:8080/healthz
  # -> ok
  ```
  포트포워드는 상주시키지 않는다 — 끝나면 종료(`kill %1` 또는 Ctrl-C).

- **dev(iwinv)**: UI를 인터넷에 노출하지 않는다. SSH 터널 위에서만 연다:
  ```bash
  ssh -i ~/.ssh/iwinv_lop -L 8080:localhost:8080 root@115.68.178.46 \
    'kubectl port-forward -n argocd svc/argocd-server 8080:443'
  ```
  이후 로컬 브라우저로 https://localhost:8080.

  접속 정보:
  - 대상 IP: `115.68.178.46`
  - SSH 키: `~/.ssh/iwinv_lop` (`root` 계정)
  - kubectl은 별도 로컬 컨텍스트 없이 SSH 세션 안에서 그대로 실행 (호스트의 k3s kubectl)

  ArgoCD와 별개로, root-app 등록 후 **배포된 백엔드 앱**은 ingress-nginx의 NodePort 31000(HTTP)으로
  검증한다(ArgoCD UI 포트포워드와는 다른 포트):
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" http://115.68.178.46:31000/lobby/
  ```
  iwinv의 ingress-nginx Service는 `LoadBalancer` 타입이며 k3s 기본 ServiceLB(klipper)가
  `.status.loadBalancer.ingress`에 노드 공인IP(`115.68.178.46`)를 채워준다 — kind의 NodePort 기반
  ingress-nginx(외부IP 미채움, Ingress 헬스체크가 영원히 `Progressing`)와 다른 상황이다.

## Admin login

- Username: `admin`
- 초기 비밀번호는 `argocd-initial-admin-secret` Secret에 자동 생성된다 (대상 클러스터의 kubectl
  컨텍스트 / SSH 세션에서 실행):
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```
- 두 클러스터 모두 개발/스테이징 성격이라 초기 비밀번호를 즉시 로테이션할 필요는 없지만, 필요하면
  `argocd account update-password`로 바꿀 수 있다.

## root-app 등록

ArgoCD를 막 설치한 상태에는 `Application`/`AppProject` 리소스가 하나도 없다. 위 클러스터 표의
root-app 경로를 그 클러스터에 apply하면 app-of-apps가 `platform`/`backend` Application을 자동으로
만든다.

```bash
# local
kubectl apply -f k8s/argocd/envs/local/root-app.yaml

# dev(iwinv) — SSH 세션 안에서, 로컬 워킹카피가 아니라 main의 raw 파일을 apply
kubectl apply -f https://raw.githubusercontent.com/Baeinsoo/infrastructure/main/k8s/argocd/envs/dev/root-app.yaml
```

## 롤백 절차 (dev/iwinv)

두 갈래로 나뉜다 — **매니페스트만 되돌리기**(GitOps는 유지)와 **GitOps 자체를 끄기**(워크로드는 유지).
실행 전에는 반드시 되돌릴 것부터 확인한다: `kubectl -n argocd get applications`로 세 Application이
`Synced`/`Healthy`인지, 문제 커밋이 무엇인지(`git log`)부터 짚는다.

### 1) 매니페스트 롤백 — 특정 커밋만 되돌리기

가장 흔한 케이스. infra `main`에서 문제를 일으킨 커밋만 `git revert`하면, ArgoCD가 다음 폴링
주기(약 3분)에 자동으로 이전 상태로 되돌린다 — 클러스터에서 아무것도 실행할 필요가 없다.

```bash
# 로컬 워킹카피에서 (infra main, 최신 pull 후)
git revert <문제-커밋-sha>
git push origin main
```

되돌아왔는지 확인 (iwinv):
```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl -n argocd get applications
  kubectl -n argocd get application backend -o jsonpath="{.status.sync.revision}"
'
```
`sync.revision`이 revert 커밋(되돌린 뒤의 최신 커밋)과 일치하면 완료. 즉시 반영하고 싶으면 3분을
기다리는 대신 ArgoCD UI(포트포워드, 위 "Access" 절)에서 `backend`/`platform` Application의
**Refresh**를 누른다 — Application을 지웠다 다시 만들 필요는 없다(그 편이 더 빠르고 목적에 맞다).

### 2) GitOps 자체를 되돌리기 — Application 삭제, 워크로드는 유지

root-app 등록 자체가 문제(예: 예상 밖의 대량 diff, 계속되는 오싱크)라 GitOps 관리를 통째로 멈추고
싶을 때.

**캐스케이드 삭제 여부는 kubectl의 `--cascade` 플래그가 아니라, Application 오브젝트에 붙은
`resources-finalizer.argocd.argoproj.io` finalizer가 결정한다.** 그 플래그는 쿠버네티스 네이티브
ownerReference 가비지 컬렉터용이고, ArgoCD는 자신이 관리하는 리소스를 지울 때 그 GC를 쓰지 않는다
— finalizer가 있으면 ArgoCD 자신이 정리하고, 없으면 Application 오브젝트만 사라진다. 지우기 전에
반드시 먼저 확인한다:

```bash
kubectl -n argocd get application <name> -o jsonpath='{.metadata.finalizers}'
```

현재(2026-08-10) 세 Application 모두 finalizer가 비어 있음을 확인했다:
```
$ kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{" finalizers="}{.metadata.finalizers}{"\n"}{end}'
backend finalizers=
platform finalizers=
root finalizers=
```
이 상태(finalizer 없음)에서는 플래그 없는 **plain** `kubectl delete application`조차 워크로드를
그대로 둔다 — finalizer가 없으면 애초에 ArgoCD의 정리 로직이 걸리지 않는다.

**주의 — ArgoCD UI/CLI로 지우면 이 전제가 깨질 수 있다.** ArgoCD UI의 cascade-delete 체크박스와
`argocd app delete`는 삭제 시점에 이 finalizer를 Application에 붙였다가 지운다 — 그러면 kubectl
플래그와 무관하게 ArgoCD 자신이 관리 리소스를 정리해 버린다. 워크로드를 보존하려면 (1) 삭제 직전
위 명령으로 finalizer가 비어 있는지 다시 확인하고, (2) **kubectl로 직접** 지운다 (ArgoCD UI/CLI
경유 금지):

```bash
ssh -i ~/.ssh/iwinv_lop root@115.68.178.46 '
  kubectl -n argocd get applications -o jsonpath="{range .items[*]}{.metadata.name}{\" finalizers=\"}{.metadata.finalizers}{\"\n\"}{end}"
  kubectl delete application root platform backend -n argocd
  kubectl get pods
'
```

이후 워크로드는 마지막으로 동기화된 상태로 계속 돌아간다 — 수동 배포(예전 `rsync` + `kubectl
apply -k`) 체제로 사실상 돌아가는 것과 같다. GitOps를 다시 켜려면 "root-app 등록" 절을 다시
수행하면 된다(ArgoCD가 기존 리소스를 다시 흡수한다 — 리소스가 이미 존재하므로 재적용이 안전하다).

### 두 절차의 차이 요약

| | 되돌리는 대상 | ArgoCD 관리 상태 | 워크로드 영향 |
|---|---|---|---|
| 1) 매니페스트 revert | 특정 변경 하나 | 유지(계속 GitOps) | 다음 폴링에 이전 상태로 롤링 |
| 2) Application 삭제 (finalizer 없음 확인 후) | GitOps 연결 자체 | 해제(Application만 삭제) | 없음(그대로 유지, 이후 수동 관리) — **finalizer가 비어 있을 때만** 성립 |

## Notes
- CRDs installed: `applications.argoproj.io`, `applicationsets.argoproj.io`,
  `appprojects.argoproj.io`.
- **local**: 이미 이 절차로 설치되어 동작 중이다 (컨텍스트 `kind-lop`).
- **dev(iwinv)**: 2026-08-10에 위 절차로 설치 완료, 7개 파드 모두 Running (스케일 다운 없음 — 위
  메모리 실측 참고). `auth-secret`/`internal-api-secret`도 이 시점에 부트스트랩됨. 라이브 서버라
  설치 전에 기존 워크로드 조사(`kubectl get deploy -A` 등)와 게임서버 이미지 프리풀
  (`crictl pull re5nardo/game-server:<tag>`)을 사전 점검으로 수행했다 — 게임서버는 상시
  Deployment가 아니라 필요 시 동적으로 뜨는 Pod라, 첫 pull이 heartbeat 임계(10초)를 넘기면 부팅
  전에 회수되는 문제를 예방하기 위함.
- **dev(iwinv) root-app 등록 완료 (2026-08-10, Task 7)**: `root`/`platform`/`backend` 세
  Application 모두 `Synced`/`Healthy`. 7월 수동 배포 잔재(`mongodb-deployment`/`mongodb-service`/
  `mongodb-pvc` — 지금 레포 매니페스트에 없어 prune 대상이 아니었다)는 삭제 완료. 이제 dev도
  local(kind)과 동일하게 GitOps로만 배포한다 — 수동 `rsync`/`kubectl apply -k`, `:latest` 이미지
  체제는 종료됨. ConfigMap 변경(`game-server-config.env`)만으로 room-server 파드가 **자동
  재시작**됨을 확인(kustomize `configMapGenerator` 해시 서픽스 + ArgoCD 동기화) — 더 이상
  "gameserver-deploy 먼저, backend-deploy 나중에" 순서를 지킬 필요가 없다.

### dev(iwinv)에 git 밖에 남아 있는 상태 (알려진 수동 산출물)

이 레포로 재구성할 수 없는, 호스트에만 있는 상태 두 가지 — 처음 보는 사람이 서프라이즈로
발견하지 않도록 여기 남긴다:

- **E2E 시드 행**: dev Postgres `Match`/`MatchRound` 테이블에 `test-match-1` /
  `test-match-1-round-0` 행이 상시로 심어져 있다(2026-08-10, Task 7). `scripts/e2e/` 스크립트를
  돌리기 위한 사전 조건 — 재현 SQL과 이유는 `scripts/e2e/README.md` 참고.
- **고아 ConfigMap**: 7월 수동 배포가 만든 이름 없는(해시 서픽스 없는) `game-server-config`
  ConfigMap이 아직 남아 있다. Age 16d(2026-08-10 기준), `GAME_SERVER_IMAGE` 값이 오래된
  sha(`959ffb4`)로 고정돼 있고, 지금 워크로드는 kustomize가 생성한 해시 서픽스 ConfigMap
  (`game-server-config-<hash>`)만 참조하므로 **미참조 상태**다. Task 6이 잡은 잔재 목록에
  없어 Task 7에서는 지우지 않고 남겨 뒀다 — 정리는 별도 작업으로.
