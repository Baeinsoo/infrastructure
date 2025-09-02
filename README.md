# League of Physical - Infrastructure

이 프로젝트는 League of Physical 게임의 인프라스트럭처 설정을 관리합니다.

## 디렉토리 구조

```
k8s/
└── local-k8s/          # 로컬 Kubernetes 환경 설정
    ├── ingress.yaml          # Ingress 설정 (라우팅)
    ├── ingress-nginx-deploy.yaml  # NGINX Ingress Controller 배포
    ├── mongodb-*             # MongoDB 데이터베이스 설정
    ├── postgres-*            # PostgreSQL 데이터베이스 설정
    ├── redis-*               # Redis 캐시 설정
    └── *-role*.yaml          # RBAC 권한 설정
```

## 배포 순서

### 1. NGINX Ingress Controller 배포
```bash
kubectl apply -f k8s/local-k8s/ingress-nginx-deploy.yaml
```

### 2. 모든 파드가 Ready 상태가 될 때까지 대기
```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=300s
```

### 3. 데이터베이스 및 서비스 배포
```bash
# PostgreSQL
kubectl apply -f k8s/local-k8s/postgres-secret.yaml
kubectl apply -f k8s/local-k8s/postgres-pvc.yaml
kubectl apply -f k8s/local-k8s/postgres-deployment.yaml
kubectl apply -f k8s/local-k8s/postgres-service.yaml

# MongoDB
kubectl apply -f k8s/local-k8s/mongodb-pvc.yaml
kubectl apply -f k8s/local-k8s/mongodb-deployment.yaml
kubectl apply -f k8s/local-k8s/mongodb-service.yaml

# Redis
kubectl apply -f k8s/local-k8s/redis-deployment.yaml
kubectl apply -f k8s/local-k8s/redis-service.yaml
```

### 4. RBAC 권한 설정
```bash
kubectl apply -f k8s/local-k8s/*-role.yaml
kubectl apply -f k8s/local-k8s/rolebinding-*.yaml
```

### 5. Ingress 설정 적용
```bash
kubectl apply -f k8s/local-k8s/ingress.yaml
```

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

# 4. Ingress 적용
kubectl apply -f k8s/local-k8s/ingress.yaml



```
## Kubernetes 서비스/Ingress 개념 요약

- ClusterIP 서비스
    - 클러스터 내부에서만 접근 가능한 서비스 타입
    - Ingress가 내부에서 접근할 대상(Target)으로 가장 많이 사용됨
    - 외부 노출이 필요 없는 백엔드 서비스들 전용

- Ingress + Ingress Controller
    - Ingress 리소스(YAML)는 단순 명세
    - Ingress Controller(Pod)가 이를 읽어 실제 라우팅(NGINX 설정 등) 구성
    - Ingress Controller 자체는 보통 Service(LoadBalancer / NodePort)로 외부 트래픽을 받음
    - 참고 파일: `k8s/local-k8s/ingress.yaml`, `k8s/local-k8s/ingress-nginx-deploy.yaml`

- 외부 노출 방식
    - Ingress Controller의 Service 타입이 아래 중 하나
        - LoadBalancer → 클라우드 로드밸런서를 통해 외부 트래픽 유입
        - NodePort → 클러스터 노드의 포트를 통해 외부 접근 가능
        - (일부 환경에서는 HostPort, HostNetwork, 혹은 MetalLB 같은 L2 로드밸런서 사용)

- Ingress 파일 자체는 명세
    - 직접 트래픽을 흘려주지 않고, "어떤 경로 → 어떤 서비스"로 연결할지 선언