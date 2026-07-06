# League of Physical - Infrastructure

이 프로젝트는 League of Physical 게임의 인프라스트럭처 설정을 관리합니다.

## 배포 모델: GitOps (ArgoCD)

이 레포는 더 이상 `kubectl apply`로 수동 배포하지 않습니다. **ArgoCD가 이 레포(`main` 브랜치)를 감시하며 클러스터 상태를 자동으로 동기화**합니다.

- 변경 = 매니페스트 수정 → 커밋 → `git push origin main` → ArgoCD가 자동 감지·sync (`automated: {prune: true, selfHeal: true}`)
- 클러스터에 직접 `kubectl apply/edit`로 넣은 변경은 selfHeal에 의해 되돌아갑니다 — Git이 항상 source of truth
- 롤백 = 문제가 된 커밋을 `git revert` 후 push (또는 ArgoCD UI/CLI의 History에서 이전 revision으로 롤백)

## 백엔드 코드 배포 (CI, Phase 2)

백엔드 서버 코드는 이 레포가 아니라 **lop-backend 모노레포**에 있다. 코드 변경 배포는 매니페스트를 손대지 않고 버튼으로 한다:

1. lop-backend에서 코드 수정·push
2. GitHub Actions → **backend-deploy** 워크플로 → `Run workflow` 버튼 (대상: all / lobby-server / matchmaking-server / room-server / db-migrate 선택)
3. 워크플로가 멀티아치(amd64+arm64) 이미지를 `re5nardo/<app>:<git-sha>`로 빌드·푸시하고, **이 레포의 `k8s/apps/backend/<app>/kustomization.yaml`의 이미지 태그를 그 sha로 bump·commit·push**
4. ArgoCD가 태그 변경을 감지해 자동 롤아웃

즉 이미지 태그는 더 이상 `:latest`가 아니라 **커밋 sha**다(재현성·롤백 가능). CI(빌드·태그) = GitHub Actions, CD(배포) = ArgoCD로 역할이 분리된다.

## 디렉토리 구조

```
k8s/
├── platform/              # ArgoCD 관리 (sync-wave 0): DB/캐시/ingress/RBAC
│   ├── postgres/
│   ├── mongodb/
│   ├── redis/
│   ├── ingress/           # lop-ingress (라우팅 규칙)
│   ├── rbac/
│   └── kustomization.yaml
├── apps/backend/           # ArgoCD 관리 (sync-wave 1): 백엔드 서버 3종 + DB 마이그레이션
│   ├── lobby-server/
│   ├── matchmaking-server/
│   ├── room-server/
│   ├── db-migrate/         # PreSync hook Job (prisma migrate deploy + seed)
│   └── kustomization.yaml
├── argocd/                  # app-of-apps 정의
│   ├── root-app.yaml        # 루트 Application (argocd 네임스페이스가 관리)
│   ├── apps/
│   │   ├── platform.yaml    # sync-wave "0" → k8s/platform
│   │   └── backend.yaml     # sync-wave "1" → k8s/apps/backend
│   └── install/              # ArgoCD 자체 설치 절차 (부트스트랩, ArgoCD 밖에서 관리)
└── local-k8s/
    └── ingress-nginx-deploy.yaml  # NGINX Ingress Controller (부트스트랩, ArgoCD 미관리)
```

`root` Application이 `k8s/argocd/apps`를 지켜보며 그 안의 `platform`/`backend` Application을 자동으로 생성·관리합니다 (app-of-apps 패턴). sync-wave로 platform(DB/redis/ingress) → backend(서버) 순서를 보장하고, `db-migrate`는 `PreSync` hook Job으로 등록되어 있어 서버 Deployment보다 먼저 실행됩니다. 그 안의 `wait-for-postgres` initContainer가 postgres 포트가 열릴 때까지 재차 대기하여 이중으로 순서를 보장합니다.

## 최초 배포 (빈 클러스터)

1. ingress-nginx 컨트롤러 설치 (부트스트랩, ArgoCD 미관리)
   ```bash
   kubectl apply -f k8s/local-k8s/ingress-nginx-deploy.yaml
   kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=300s
   ```
2. ArgoCD 설치 (부트스트랩, 절차는 `k8s/argocd/install/README.md` 참고)
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
   ```
3. app-of-apps 등록 (이후 모든 배포는 Git push로 자동화됨)
   ```bash
   kubectl apply -f k8s/argocd/root-app.yaml
   ```

## ArgoCD 접속

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
```
→ https://localhost:8080 (self-signed 인증서 경고는 무시)

- Username: `admin`
- 초기 비밀번호:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  ```

상태 확인:
```bash
kubectl get applications -n argocd
```
`root` / `platform` / `backend` 모두 `Synced` + `Healthy`가 정상 상태입니다.

## 외부 접근

ingress-nginx는 NodePort(HTTP 31000 / HTTPS 32000)로 노출되어 있습니다.

```
http://localhost:31000/lobby/
http://localhost:31000/matchmaking/
http://localhost:31000/room/
```

## 애플리케이션 이미지

현재 백엔드 서버들은 `re5nardo/*:latest` 이미지를 사용합니다 (Phase 1 범위). CI에서 커밋 SHA 태그를 빌드·푸시하고 `kustomize edit set image`로 자동 반영하는 것은 Phase 2 작업입니다.

## 트러블슈팅

### Ingress Admission Webhook 오류

**에러 메시지:**
```
error when creating "ingress.yaml": Internal error occurred: failed calling webhook "validate.nginx.ingress.kubernetes.io": failed to call webhook: Post "https://ingress-nginx-controller-admission.ingress-nginx.svc:443/networking/v1/ingresses?timeout=10s": dial tcp 10.109.166.63:443: connect: connection refused
```

**원인:**
- NGINX Ingress Controller의 admission webhook이 완전히 준비되기 전에 ingress를 적용하려고 할 때 발생
- Admission webhook이 일시적으로 연결 불가능한 상태

**해결 방법:**

#### 방법 1: 순서대로 배포 (권장)
```bash
# 1. Ingress Controller 먼저 배포
kubectl apply -f k8s/local-k8s/ingress-nginx-deploy.yaml

# 2. 완전히 준비될 때까지 대기
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=300s

# 3. Admission webhook 상태 확인
kubectl get validatingwebhookconfigurations ingress-nginx-admission

# 4. Ingress 적용 (ArgoCD 관리 하에서는 위 root-app 등록만으로 자동 적용됨)
kubectl apply -k k8s/platform/ingress
```

> 참고: ArgoCD가 `k8s/platform`을 관리하는 정상 운영 상태에서는 이 문제가 sync-wave 덕분에 거의 발생하지 않습니다 (ingress-nginx 컨트롤러는 클러스터 부트스트랩 단계에서 미리 준비되어 있어야 함). 위 절차는 ingress-nginx 컨트롤러를 새로 설치하거나 재현할 때 참고용입니다.

## Kubernetes 서비스/Ingress 개념 요약

- ClusterIP 서비스
    - 클러스터 내부에서만 접근 가능한 서비스 타입
    - Ingress가 내부에서 접근할 대상(Target)으로 가장 많이 사용됨
    - 외부 노출이 필요 없는 백엔드 서비스들 전용

- Ingress + Ingress Controller
    - Ingress 리소스(YAML)는 단순 명세
    - Ingress Controller(Pod)가 이를 읽어 실제 라우팅(NGINX 설정 등) 구성
    - Ingress Controller 자체는 보통 Service(LoadBalancer / NodePort)로 외부 트래픽을 받음
    - 참고 파일: `k8s/platform/ingress/ingress.yaml`, `k8s/local-k8s/ingress-nginx-deploy.yaml`

- 외부 노출 방식
    - Ingress Controller의 Service 타입이 아래 중 하나
        - LoadBalancer → 클라우드 로드밸런서를 통해 외부 트래픽 유입
        - NodePort → 클러스터 노드의 포트를 통해 외부 접근 가능
        - (일부 환경에서는 HostPort, HostNetwork, 혹은 MetalLB 같은 L2 로드밸런서 사용)

- Ingress 파일 자체는 명세
    - 직접 트래픽을 흘려주지 않고, "어떤 경로 → 어떤 서비스"로 연결할지 선언

## 더 알아보기

- ArgoCD app-of-apps 구조/운영 상세: `k8s/argocd/README.md`
- ArgoCD 설치 절차: `k8s/argocd/install/README.md`
