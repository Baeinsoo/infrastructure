# 로컬 MinIO (호스트 docker-compose)

kind 클러스터(`kind-lop`) 안이 아니라 **호스트 도커**에서 돈다. CNPG(`Cluster lop-db`)의 WAL
아카이브·백업이 쓰는 `s3://lop-db-backup/`을 로컬에서 흉내 내기 위한 용도다. kind 노드 컨테이너가
`host.docker.internal:9000`으로 이 MinIO에 닿는다(`k8s/envs/local/platform/objectstore-patch.yaml`).

## 이미지 메모 (2026-10-12)

MinIO가 2025-10에 "소스 전용 배포"로 전환해 `docker.io/minio/minio`·`quay.io/minio/minio` 공식
이미지 배포를 전부 중단했다(https://github.com/minio/minio/issues/21647). 그래서 아래 두 이미지는
공식 `minio/minio`·`minio/mc`가 아니다:

- `coollabsio/minio` — 같은 업스트림 소스를 그대로 빌드하는 커뮤니티 미러. 태그는 실제 minio
  릴리스 태그를 그대로 따른다.
- `amazon/aws-cli` — 버킷 생성(`mc mb`가 하던 일)을 AWS 공식 CLI로 대체. S3 호환 엔드포인트라
  `mc`를 꼭 쓸 필요가 없다.

새로 태그를 올릴 땐 `docker manifest inspect <image>:<tag>`로 먼저 존재를 확인할 것 — 이번에
브리프가 지정한 공식 태그 두 개가 전부 더는 받아지지 않는 상태였다.

## 기동

```bash
cd k8s/local-k8s/minio
docker compose up -d
```

`mkbucket` 컨테이너가 MinIO가 뜨길 기다렸다가 `lop-db-backup` 버킷을 만들고 종료한다(한 번 떠 있으면
재실행해도 안전 — 이미 있으면 그냥 넘어간다).

## 중지

```bash
docker compose down        # 데이터는 ./data에 남는다
docker compose down -v     # 데이터까지 지울 때만
```

## 데이터 디렉터리

`./data`는 git에 커밋하지 않는다(레포 루트 `.gitignore`의 `k8s/local-k8s/minio/data/`).

## kind 노드에서 닿는지 확인

```bash
docker exec lop-control-plane curl -s http://host.docker.internal:9000/minio/health/live
```

빈 응답 + 종료코드 0이면 정상(헬스 엔드포인트는 본문이 없다). `host.docker.internal`은 kind 노드가
Docker Desktop이 띄운 컨테이너라 별도 설정 없이 자동으로 풀린다 — 연결이 안 되면 보통 MinIO
컨테이너가 안 떠 있거나(`docker compose ps`) 방화벽이 9000 포트를 막은 경우다.

위 확인은 **노드 컨테이너**(`docker exec`) 기준이다. CNPG가 실제로 쓰는 경로는 **파드 안**(CNI
네트워크 네임스페이스, 노드와 라우팅/DNS가 다를 수 있음)이라 따로 확인한다:

```bash
kubectl --context kind-lop run --rm -it curl --image=curlimages/curl --restart=Never -- \
  curl -s http://host.docker.internal:9000/minio/health/live
```

이 파드가 끝까지 응답을 못 받고 멈추면(노드 확인은 됐는데 이것만 실패하면) CNI 쪽에서
`host.docker.internal`이 안 풀리거나 막힌 경우다 — kind 네트워크 설정을 다시 본다.

## 콘솔

```
http://localhost:9001
```

`lopminio` / `lopminio-secret`로 로그인.
