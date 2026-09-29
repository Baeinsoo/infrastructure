# infrastructure

@../league-of-physical/CLAUDE.md

위 줄이 모든 repo 공통 규칙(답변 스타일·주석·푸시 규약·문서 규칙)을 불러온다.
여러 repo에 걸친 문서는 형제 repo `league-of-physical`의 `docs/`에 있다(지도: `../league-of-physical/docs/README.md`).
이 repo 안에서만 의미 있는 README·운영 절차는 여기에 둔다.

k8s 매니페스트(GitOps 진실원본, ArgoCD)와 MasterData 파이프라인(`table/`).

## 이 repo 전용 규칙

- **새 백엔드 서비스(외부에 노출할 라우트)를 추가하면 `k8s/base/platform/ingress/ingress.yaml`에 경로를 더한다.**
  local·dev 두 환경이 이 파일을 공유한다(환경별 오버레이 없음). 기존 경로처럼 `/internal`은 막는 정규식을 쓴다(ADR-0011).
