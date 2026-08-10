# ingress-nginx 컨트롤러

컨트롤러(`../../local-k8s/ingress-nginx-deploy.yaml`, v1.12.0-beta.0)는 이미 클러스터의
`ingress-nginx` 네임스페이스에 설치되어 NodePort 31000(HTTP)/32000(HTTPS)로 동작 중이다.
부트스트랩 컴포넌트이므로 ArgoCD 관리 대상이 아니다(teardown 대상도 아님).
이 디렉토리의 `ingress.yaml`(lop-ingress 라우팅)만 ArgoCD(platform)가 관리한다.
재설치 필요 시: kubectl apply -f k8s/local-k8s/ingress-nginx-deploy.yaml
