# 아직 참조되지 않음

`k8s/argocd/envs/dev/apps/platform.yaml`은 지금 이 디렉터리가 아니라 `k8s/base/platform`을 가리킨다
(dev는 이번 CNPG 전환에서 무변경 — local만 CNPG로 바뀌었다). 이 디렉터리의 파일(`kustomization.yaml`,
`cluster-patch.yaml`, `objectstore-patch.yaml`, `backup-creds-secret.yaml`)은 dev를 CNPG로 옮길 때 쓸
준비물이다. dev 전환 시 할 일:

1. `kustomization.yaml`의 `resources`에 `../../../base/platform/postgres-cnpg`를 추가(local의
   `k8s/envs/local/platform/kustomization.yaml`과 같은 모양 — 지금은 이게 없어서 `cluster-patch.yaml`/
   `objectstore-patch.yaml`의 `target`이 가리키는 `Cluster`/`ObjectStore`가 없어 두 patch가 조용히
   no-op된다).
2. `k8s/base/platform/postgres/kustomization.yaml`에서 옛 postgres 4개를 빼는 시점이면(Task 6) 여기도
   같이 정리.
3. `k8s/argocd/envs/dev/apps/platform.yaml`의 `path`를 `k8s/base/platform` → `k8s/envs/dev/platform`으로.
