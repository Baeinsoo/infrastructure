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

## Notes
- CRDs installed: `applications.argoproj.io`, `applicationsets.argoproj.io`,
  `appprojects.argoproj.io`.
- **local**: 이미 이 절차로 설치되어 동작 중이다 (컨텍스트 `kind-lop`).
- **dev(iwinv)**: 아직 설치 전이다. 위 절차는 그대로 적용되지만, 라이브 서버이므로 설치 전에 기존
  워크로드 조사·시크릿 부트스트랩·이미지 프리풀 같은 사전 점검이 추가로 필요하다.
