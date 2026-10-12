# DB 운영 — CloudNativePG `lop-db`

설계: `league-of-physical/docs/archive/specs/2026-10-12-cnpg-backup-pitr-design.md` · 계획: `…/docs/superpowers/plans/2026-10-12-cnpg-backup-pitr.md`
적용 범위: **local(kind `lop`)** 전환 완료(2026-10-12). dev(iwinv)는 아직 옛 postgres Deployment — 전환 절차는 §6.

## 1. 모양

| | 값 |
|---|---|
| 클러스터 | `Cluster lop-db`(ns `default`), 쓰기 서비스 `lop-db-rw`, DB `lop` |
| 롤 | `lop_app`(앱 — 원장 `LedgerTransaction`/`LedgerEntry`·`_prisma_migrations` UPDATE/DELETE 불가, `lock_timeout 5s`·`statement_timeout 15s`·`idle_in_transaction_session_timeout 30s`) · `lop_migrator`(앱 DB 소유자, CREATEROLE, `lop_app` ADMIN — 마이그레이션 전용) · 슈퍼유저 접근 꺼짐 |
| 시크릿 | `lop-db-app-user`, `lop-db-migrator`(basic-auth) · `lop-db-backup-creds`(저장소 키) |
| 백업 | `ObjectStore lop-db-backup` → local MinIO `http://host.docker.internal:9000`(호스트 도커, `k8s/local-k8s/minio/`), 보존 30일 · `ScheduledBackup lop-db-nightly` 04:00 KST · WAL 연속 아카이브(`archive_timeout 300s`, RPO ≤ 5분) |
| 저장소 폴더 | `s3://lop-db-backup/<serverName>/` — serverName은 `k8s/envs/local/platform/cluster-patch.yaml`의 `plugins[0].parameters.serverName`(지금 `lop-db-20261012`). **복원할 때마다 바뀐다**(§4) |
| 매니페스트 | `k8s/base/platform/postgres-cnpg/`(공통) + `k8s/envs/<env>/platform/`(엔드포인트·인스턴스·디스크·serverName). ArgoCD `platform` 앱(local)은 `k8s/envs/local/platform` |

## 2. 접속·조회

```bash
# 슈퍼유저(파드 안 유닉스 소켓 — 네트워크로는 막혀 있다)
kubectl exec -n default lop-db-1 -c postgres -- psql -U postgres -d lop -c '...'
# 앱 롤로(권한 확인용)
kubectl exec -n default lop-db-1 -c postgres -- env PGPASSWORD=<lop-db-app-user.password> psql -h lop-db-rw -U lop_app -d lop -c '...'
# 상태
kubectl get cluster -n default lop-db -o jsonpath='{.status.phase}{" "}{range .status.conditions[*]}{.type}={.status} {end}'
kubectl get backup -n default            # 야간 백업 결과(completed)
```
`ContinuousArchiving=False`면 저장소(MinIO/S3)가 안 닿는 것 — §5.

## 3. 백업

- 야간 베이스 백업은 `ScheduledBackup`이 만든다. 수동: `kubectl cnpg backup lop-db --method plugin --plugin-name barman-cloud.cloudnative-pg.io`(플러그인 없으면 `Backup` CR을 직접 만든다 — `k8s/base/platform/postgres-cnpg/scheduledbackup.yaml`의 spec과 같은 `method/pluginConfiguration`).
- WAL은 쓰기가 있을 때마다, 적어도 5분마다 아카이브된다. 저장소 확인:
  `docker run --rm --network host -e AWS_ACCESS_KEY_ID=lopminio -e AWS_SECRET_ACCESS_KEY=lopminio-secret amazon/aws-cli:2.37.12 --endpoint-url http://localhost:9000 s3 ls --recursive s3://lop-db-backup/`
- **복원점**: `db-migrate` Job이 마이그레이션 직전에 `pre-migrate-<UTC 타임스탬프>`를 남긴다(`SELECT pg_create_restore_point(...)`, 권한은 `lop_migrator`에 GRANT EXECUTE). 이름은 `pg_waldump`에서 `RESTORE_POINT`로 보인다. 복구 때는 이름보다 **시각/LSN**이 안전하다(같은 이름이 여럿이면 처음 것에서 멈춘다).

## 4. 복구 — 제자리가 아니라 새로 띄운다

CNPG는 기존 클러스터를 되감지 않는다. **백업에서 새 클러스터를 부트스트랩**한다.

1. ArgoCD 자동 동기 끄기: `root` → `platform` → `backend` 순으로 `kubectl -n argocd patch app <앱> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`(root를 먼저 — root가 자식 앱 spec을 되돌린다. root를 수동 동기하면 자식의 automated가 되살아나니 다시 끈다).
2. 백엔드 쓰기 정지: `kubectl scale deploy -n default lobby-server matchmaking-server matchmaking-director room-server --replicas=0`.
3. (살아 있으면) 마지막 WAL 밀어내기: `psql -c "select pg_switch_wal()"` 뒤 `ContinuousArchiving=True`와 저장소의 마지막 세그먼트 확인.
4. 복원 대상을 정한다:
   - **끝까지**(기본): `recoveryTarget` 없음.
   - **시점**: `recoveryTarget.targetTime: "<RFC3339>"` — **마지막 커밋보다 이전 시각**이어야 한다. 더 뒤면 PostgreSQL이 `recovery ended before configured recovery target was reached`로 멈춘다(10-12 1차 훈련이 이걸로 실패).
   - 이름: `targetName: pre-migrate-…`.
5. 매니페스트: `kubectl kustomize k8s/envs/local/platform`의 `Cluster`를 가져와 ① `bootstrap`을 `recovery: { source: lop-db-origin, recoveryTarget: … }`로 ② `externalClusters: [{ name: lop-db-origin, plugin: { name: barman-cloud.cloudnative-pg.io, parameters: { barmanObjectName: lop-db-backup, serverName: <백업을 남긴 폴더, 지금 lop-db-20261012> } } }]` ③ `plugins[0].parameters.serverName`을 **새 폴더 이름**(예 `lop-db-YYYYMMDD`)으로. 옛 클러스터가 아직 있으면 `kubectl delete cluster lop-db`(PVC도 지워진다 — 저장소의 백업은 남는다).
6. 적용 `kubectl apply --server-side --field-manager=cutover -f …` → `status.phase`가 `Cluster in healthy state`.
7. 확인: 행 수·통화별 잔액 합(대사 쿼리) 0·마지막 거래, `pg_auth_members`에 `lop_migrator→lop_app admin_option=t`, `lop_app`으로 원장 UPDATE 거부, `lop_migrator`로 `ALTER ROLE lop_app SET lock_timeout='5s'` 성공, `ContinuousArchiving=True`(새 폴더).
8. 백엔드 복귀: `k8s/envs/local/platform/cluster-patch.yaml`의 `serverName`을 새 값으로 **커밋**(안 그러면 자동 동기가 옛 값으로 되돌려 아카이브가 충돌한다) → backend 앱 수동 동기(`kubectl -n argocd patch app backend --type merge -p '{"operation":{"sync":{"revision":"HEAD","prune":true}}}'`) → 로비 로그 `postgres loaded and connected` → 대사 잡 1회(`kubectl create job --from=cronjob/lobby-economy-reconcile <이름>`) clean.
9. 자동 동기 복구(platform → backend → root). 그 전에 main의 매니페스트와 살아 있는 클러스터가 같은지(`kubectl diff` 또는 ArgoCD diff) 본다.

**특정 유저만 되살릴 때**는 운영 DB를 덮어쓰지 않는다 — 별도 이름으로 복원해 원장을 읽고, 운영 DB엔 `POST /internal/economy/adjust`로 차액만 적는다.

## 5. 저장소가 끊겼을 때

MinIO(또는 S3)가 안 닿으면 **DB는 계속 서비스**하고 WAL만 쌓인다(`ContinuousArchiving=False`, 10-12 실측: 끊고 20초 안에 표시, 복구 뒤 20초 안에 따라붙음). WAL 볼륨(`walStorage` 1Gi)이 차면 PostgreSQL이 멈추므로, 쓰기가 많을 땐 오래 두지 않는다. 호스트 재시작 뒤 MinIO가 안 떠 있으면 `docker compose -f k8s/local-k8s/minio/docker-compose.yml up -d`(`restart: unless-stopped`라 보통은 스스로 뜬다).

## 6. 훈련 기록

| 날짜 | 무엇 | 결과 | RTO |
|---|---|---|---|
| 2026-10-12 | local 전환(import) 직후 클러스터 삭제 → 백업에서 복원 | 1차 `targetTime 08:35:00Z` 실패(마지막 커밋 08:31보다 뒤). 2차 끝까지 복원 성공 — 493 매치(마지막 포함)·거래 10·잔액 합 0·권한·멤버십 유지, 새 폴더로 아카이브 재개 | 삭제 08:52:49Z → healthy 08:54:01Z = **1분 12초**(백엔드 복귀 별도 ~2분) |

다음 훈련: 월 1회(ROADMAP 파킹). 훈련마다 이 표에 한 줄.

## 7. dev(iwinv) 전환 — 아직 안 함

local과 같은 절차(계획 Task 5 체크리스트). 다른 점: ① S3 버킷 `lop-db-backup`(버전 관리 켬) + **삭제 권한 없는 전용 IAM 키**를 `k8s/envs/dev/platform/backup-creds-secret.yaml`(지금 `REPLACE-ME`)에 ② `k8s/argocd/envs/dev/apps/platform.yaml`의 `path`를 `k8s/envs/dev/platform`으로, `operators.yaml`을 dev에도 추가 ③ `k8s/base/platform/kustomization.yaml`에 `postgres-cnpg`를 넣고 옛 `postgres`를 뺀다(local은 오버레이에서 옛 것을 `$patch: delete`로 지워 둔 상태) ④ `k8s/envs/dev/backend`에 local과 같은 접속 패치 6개. dev ArgoCD가 main을 보고 있으므로 **머지 전에 dev의 자동 동기를 끈다**.

## 8. 옛 postgres 정리

전환 뒤 옛 `postgres-deployment`·`postgres-service`·`postgres-secret`은 local 오버레이에서 지웠고, **PVC `postgres-pvc`는 1주 보존**(`argocd.argoproj.io/sync-options: Prune=false`). 2026-10-19 이후 `kubectl delete pvc -n default postgres-pvc`로 지우고 base의 PVC 매니페스트도 뺀다(dev 전환 때 같이).
