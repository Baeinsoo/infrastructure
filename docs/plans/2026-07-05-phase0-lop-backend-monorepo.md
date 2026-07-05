# Phase 0: lop-backend 모노레포 통합 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** lobby/matchmaking/room 서버 3개 + db-admin을 `lop-backend` pnpm 모노레포 하나로 통합하고, Prisma 스키마를 `@lop/database` 패키지로 단일화한다.

**Architecture:** `apps/`(서버 3종, 각자 독립 배포 단위) + `packages/database`(Prisma 스키마 단일 소유자, 구 db-admin 승계). Turborepo가 빌드 오케스트레이션. 각 앱의 Dockerfile은 workspace 루트 컨텍스트 + `pnpm deploy` 패턴.

**Tech Stack:** Node 22, pnpm 10.11.0 (설치됨), Turborepo 2, TypeScript 5.7, Prisma 6.6, Express 4.

**설계 문서:** `infrastructure/docs/specs/2026-07-05-deployment-system-design.md`

## Global Constraints

- 새 레포 위치: `/Users/insoobae/workspace/LOP/lop-backend`. 원본 레포 4개는 **수정·삭제하지 않는다** (archive는 Phase 2 완료 후).
- Prisma 버전은 `^6.6.0`으로 통일 (db-admin 기준. lobby 등은 ^6.3.1였음).
- 앱 이관 시 **가져가지 않는 것**: `prisma/`(→ @lop/database), `k8s/`(→ Phase 1에서 infrastructure로), `scripts/`(→ Phase 2 워크플로로 대체), `Dockerfile`(Task 6에서 재작성), `package-lock.json`(pnpm 전환), room의 `dist/`·`node_modules/`·`server_binary/`(빌드 산출물·Unity 바이너리).
- `.env.development.local`, `.env.development.local-k8s`는 원본 레포에 **git 커밋되어 있는 파일**이며 로컬 전용 값만 있음 — 그대로 가져가고 gitignore하지 않는다 (기존 Dockerfile이 `COPY . .`으로 포함시키는 관례 유지).
- 스펙의 `packages/shared`(@lop/shared)는 Phase 0에서 **의도적으로 생성하지 않는다** — 지금 옮길 실체(공유 타입)가 없고, 첫 공유 타입이 생기는 시점에 추가 (YAGNI).
- 각 앱의 `lua/` 디렉토리는 lobby·matchmaking 간 동일하지만 런타임 경로 의존이 있어 Phase 0에서는 앱별로 유지 (중복 제거는 이후 과제).
- 이 프로젝트에는 기존 테스트가 없다. 이 마이그레이션의 "테스트"는 **① `prisma validate` ② `turbo run build` 전체 통과 ③ 각 서버 부팅 스모크 ④ docker build 성공**이다.
- 부팅 스모크는 로컬에서 postgres(5432)/mongo(27017)/redis(6379)가 접근 가능해야 한다 (`kubectl port-forward` 또는 기존 로컬 DB). 불가하면 "DB 연결 시도 로그까지 출력하고 죽는 것"을 부팅 성공으로 간주.

---

### Task 1: lop-backend 워크스페이스 스캐폴드

**Files:**
- Create: `lop-backend/.gitignore`, `lop-backend/package.json`, `lop-backend/pnpm-workspace.yaml`, `lop-backend/turbo.json`, `lop-backend/tsconfig.base.json`

**Interfaces:**
- Produces: 이후 모든 Task가 의존하는 workspace 루트. `tsconfig.base.json`은 앱들이 `extends`할 공통 설정.

- [ ] **Step 1: 디렉토리 + git init**

```bash
mkdir -p /Users/insoobae/workspace/LOP/lop-backend/{apps,packages}
cd /Users/insoobae/workspace/LOP/lop-backend
git init -b main
```

- [ ] **Step 2: 루트 파일 작성**

`.gitignore`:
```
node_modules/
dist/
generated/
.turbo/
logs/
*.log
.DS_Store
# .env.development.local* 은 로컬 전용 값만 담고 있어 의도적으로 커밋함 (기존 관례)
```

`package.json`:
```json
{
    "name": "lop-backend",
    "version": "0.0.0",
    "private": true,
    "packageManager": "pnpm@10.11.0",
    "scripts": {
        "build": "turbo run build"
    },
    "devDependencies": {
        "turbo": "^2.5.0"
    }
}
```

`pnpm-workspace.yaml`:
```yaml
packages:
  - "apps/*"
  - "packages/*"
```

`turbo.json`:
```json
{
    "$schema": "https://turbo.build/schema.json",
    "tasks": {
        "build": {
            "dependsOn": ["^build"],
            "outputs": ["dist/**", "generated/**"]
        }
    }
}
```

`tsconfig.base.json` (3개 앱 tsconfig의 공통부 — 원본과 동일 값):
```json
{
    "compilerOptions": {
        "module": "commonjs",
        "target": "es6",
        "lib": ["es6"],
        "pretty": true,
        "sourceMap": true,
        "outDir": "dist",
        "strict": true,
        "esModuleInterop": true,
        "experimentalDecorators": true,
        "strictPropertyInitialization": false,
        "moduleResolution": "node"
    }
}
```

- [ ] **Step 3: 검증 — pnpm/turbo 동작**

```bash
pnpm install
pnpm build
```
Expected: install 성공, `turbo run build`가 "no tasks were executed" 류 메시지로 정상 종료 (패키지 아직 없음).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "chore: scaffold lop-backend pnpm workspace"
```

---

### Task 2: packages/database — db-admin 승계 + 스키마 단일화

**Files:**
- Create: `packages/database/package.json`, `packages/database/prisma/schema.prisma`(db-admin 복사+수정), `packages/database/prisma/migrations/`(복사), `packages/database/src/seed.ts`(복사+수정), `packages/database/tables/*.csv`(복사)

**Interfaces:**
- Produces: `@lop/database` 패키지. 앱들은 `import { PrismaClient, User, ... } from '@lop/database'`로 사용. main/types가 생성된 클라이언트(`generated/client`)를 직접 가리키므로 tsc 빌드 없음 — `build` 스크립트 = `prisma generate`.

- [ ] **Step 1: db-admin 내용물 복사**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
mkdir -p packages/database/src
cp -R ../db-admin/prisma packages/database/prisma
cp ../db-admin/src/seed.ts packages/database/src/seed.ts
cp -R ../db-admin/tables packages/database/tables
```

- [ ] **Step 2: package.json 작성**

`packages/database/package.json`:
```json
{
    "name": "@lop/database",
    "version": "0.0.0",
    "private": true,
    "main": "./generated/client/index.js",
    "types": "./generated/client/index.d.ts",
    "scripts": {
        "build": "prisma generate",
        "generate": "prisma generate",
        "migrate:dev": "prisma migrate dev",
        "migrate:deploy": "prisma migrate deploy",
        "seed": "ts-node src/seed.ts"
    },
    "dependencies": {
        "@prisma/client": "^6.6.0",
        "csv-parse": "^5.6.0",
        "dotenv": "^16.5.0"
    },
    "devDependencies": {
        "prisma": "^6.6.0",
        "ts-node": "^10.9.2",
        "typescript": "^5.8.3"
    }
}
```

- [ ] **Step 3: generator output 변경**

`packages/database/prisma/schema.prisma`의 generator 블록을 다음으로 교체:
```prisma
generator client {
  provider = "prisma-client-js"
  output   = "../generated/client"
}
```

`src/seed.ts`의 import를 수정:
```ts
// 변경 전: import { PrismaClient } from '@prisma/client';
import { PrismaClient } from '../generated/client';
```

- [ ] **Step 4: 서버 스키마와 필드 단위 대조 (스키마 갈라짐 검증)**

db-admin 스키마는 모델 목록 기준으로 3개 서버 스키마의 **상위집합**임이 확인됨. 필드 단위 차이를 검증:

```bash
cd /Users/insoobae/workspace/LOP
for s in LeagueOfPhysical-LobbyServer/LobbyServer LeagueOfPhysical-MatchmakingServer/MatchmakingServer LeagueOfPhysical-RoomServer/RoomServer; do
  echo "===== $s ====="
  diff <(grep -vE '^\s*(//|$)' lop-backend/packages/database/prisma/schema.prisma | tr -s ' ') \
       <(grep -vE '^\s*(//|$)' $s/prisma/schema.prisma | tr -s ' ') | grep '^>' || echo "(서버 쪽에만 있는 내용 없음)"
done
```
Expected: `>` 줄(서버 스키마에만 있는 내용)이 **모델/필드 수준에서는 없어야** 함 (generator·datasource 블록 차이는 무시).
**만약 서버 쪽에만 있는 필드가 발견되면**: 실제 DB는 db-admin이 만들었으므로 그 필드는 DB에 없을 가능성이 높다 — 해당 서버 코드가 그 필드를 실제로 사용하는지 확인 후, 사용한다면 통합 스키마에 필드를 추가하고 Step 5의 migrate diff로 신규 마이그레이션을 생성한다. 사용하지 않으면 무시.

- [ ] **Step 5: 마이그레이션 정합성 검증**

기존 DB는 `prisma db push`로 만들어졌을 가능성이 있음(infrastructure/TODO.md). 마이그레이션 폴더가 현재 스키마를 온전히 표현하는지 확인:

```bash
cd /Users/insoobae/workspace/LOP/lop-backend/packages/database
pnpm install
npx prisma validate
npx prisma migrate diff --from-migrations prisma/migrations --to-schema-datamodel prisma/schema.prisma --shadow-database-url "postgresql://postgres:testpw@localhost:5432/prisma_shadow"
```
Expected: `No difference detected`.
- diff가 나오면: `npx prisma migrate dev --create-only --name sync_schema`로 보정 마이그레이션 생성 (DATABASE_URL 필요 — `.env`에 `postgresql://postgres:testpw@localhost:5432/postgres?schema=public` 사용, db-admin README와 동일).
- shadow DB용 postgres가 없으면 이 검증은 Phase 1(PreSync Job 구성 시)로 이연하고 주석으로 기록.
- **운영 노트 (Phase 1에서 사용)**: 기존 DB에 처음 `migrate deploy`를 적용하기 전에 베이스라인 필요:
  `npx prisma migrate resolve --applied 20250902145642_init`

- [ ] **Step 6: 생성 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
pnpm install
pnpm --filter @lop/database build
node -e "const {PrismaClient}=require('./packages/database/generated/client'); console.log(typeof PrismaClient)"
```
Expected: generate 성공, `function` 출력.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: add @lop/database package (succeeds db-admin, single schema owner)"
```

---

### Task 3: lobby-server 이관

**Files:**
- Create: `apps/lobby-server/` (원본 `LeagueOfPhysical-LobbyServer/LobbyServer/`에서 복사)
- Modify: `apps/lobby-server/package.json`, `apps/lobby-server/tsconfig.json`, `apps/lobby-server/src/**`(import 치환)

**Interfaces:**
- Consumes: `@lop/database` (Task 2)
- Produces: `pnpm --filter lobby-server build/start` 가능한 앱. 빌드 산출물 `dist/main.js`.

- [ ] **Step 1: 소스 복사 (제외 목록 적용)**

```bash
cd /Users/insoobae/workspace/LOP
rsync -a --exclude node_modules --exclude dist --exclude prisma --exclude k8s \
  --exclude scripts --exclude Dockerfile --exclude package-lock.json \
  LeagueOfPhysical-LobbyServer/LobbyServer/ lop-backend/apps/lobby-server/
```

- [ ] **Step 2: package.json 수정**

`apps/lobby-server/package.json` — dependencies에서 `@prisma/client` 제거, devDependencies에서 `prisma` 제거, 다음 추가:
```json
"dependencies": {
    "@lop/database": "workspace:*",
    ...(기존 나머지 유지)
}
```
scripts는 그대로 (`build`: `tsc --build && tsc-alias`).

- [ ] **Step 3: tsconfig.json을 base 상속으로 변경**

`apps/lobby-server/tsconfig.json` — 공통 옵션 제거하고 상속:
```json
{
    "extends": "../../tsconfig.base.json",
    "compilerOptions": {
        "baseUrl": ".",
        "paths": {
            "@src/*": ["src/*"],
            "@controllers/*": ["src/controllers/*"],
            "@exceptions/*": ["src/exceptions/*"],
            "@interfaces/*": ["src/interfaces/*"],
            "@middlewares/*": ["src/middlewares/*"],
            "@models/*": ["src/models/*"],
            "@routes/*": ["src/routes/*"],
            "@services/*": ["src/services/*"],
            "@utils/*": ["src/utils/*"],
            "@dtos/*": ["src/dtos/*"],
            "@daos/*": ["src/daos/*"],
            "@repositories/*": ["src/repositories/*"],
            "@databases/*": ["src/databases/*"],
            "@caches/*": ["src/caches/*"],
            "@loaders/*": ["src/loaders/*"],
            "@factories/*": ["src/factories/*"],
            "@mappers/*": ["src/mappers/*"],
            "@config": ["src/config"]
        }
    },
    "include": ["src/**/*"],
    "exclude": ["node_modules", "src/logs"]
}
```

- [ ] **Step 4: `@prisma/client` import를 `@lop/database`로 치환**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend/apps/lobby-server
grep -rl "@prisma/client" src | xargs sed -i '' "s|'@prisma/client'|'@lop/database'|g"
grep -rn "@prisma/client" src && echo "잔여 있음 — 확인 필요" || echo OK
```
Expected: `OK`.

- [ ] **Step 5: 빌드 검증 (스키마 갈라짐이 여기서 드러남)**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
pnpm install
pnpm --filter lobby-server build
```
Expected: PASS. 타입 에러가 나면 대부분 "서버 사본 스키마에는 있었는데 통합 스키마에 없는 필드" — Task 2 Step 4의 규칙대로 통합 스키마에 반영 후 `pnpm --filter @lop/database build` 재실행.

- [ ] **Step 6: 부팅 스모크**

```bash
nc -z localhost 5432 && nc -z localhost 27017 && nc -z localhost 6379 && echo DB_OK
cd apps/lobby-server && NODE_ENV=development node dist/main
```
Expected: `DB_OK`이면 리슨 로그(PORT 1340)까지 출력. DB 미가동이면 DB 연결 시도 로그 확인 후 종료로 갈음.

- [ ] **Step 7: Commit**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
git add -A && git commit -m "feat: migrate lobby-server into monorepo (@lop/database)"
```

---

### Task 4: matchmaking-server 이관

**Files:**
- Create: `apps/matchmaking-server/` (원본 `LeagueOfPhysical-MatchmakingServer/MatchmakingServer/`. `master_data/` 포함)
- Modify: 동일 파일 3종 (package.json / tsconfig.json / src import)

**Interfaces:**
- Consumes: `@lop/database`
- Produces: `pnpm --filter matchmaking-server build/start`

Task 3과 동일 절차를 matchmaking-server에 적용한다. 명령을 그대로 기록:

- [ ] **Step 1: 복사**

```bash
cd /Users/insoobae/workspace/LOP
rsync -a --exclude node_modules --exclude dist --exclude prisma --exclude k8s \
  --exclude scripts --exclude Dockerfile --exclude package-lock.json \
  LeagueOfPhysical-MatchmakingServer/MatchmakingServer/ lop-backend/apps/matchmaking-server/
```
(`master_data/`, `lua/`는 exclude에 없으므로 자동 포함 — 코드가 앱 디렉토리 기준 상대경로로 읽으므로 그대로 동작)

- [ ] **Step 2: package.json 수정** — dependencies에서 `@prisma/client` 제거, devDependencies에서 `prisma` 제거, dependencies에 `"@lop/database": "workspace:*"` 추가. scripts는 그대로.

- [ ] **Step 3: tsconfig.json을 base 상속으로 교체** (원본이 lobby와 완전 동일함을 확인했으므로 결과물도 동일). **주의: `outDir`을 명시해야 한다** — base의 `outDir`은 base 파일 위치(모노레포 루트) 기준으로 해석돼 산출물이 루트 `dist/`로 새어나감. Task 3에서 확인된 이슈:

```json
{
    "extends": "../../tsconfig.base.json",
    "compilerOptions": {
        "outDir": "dist",
        "baseUrl": ".",
        "paths": {
            "@src/*": ["src/*"],
            "@controllers/*": ["src/controllers/*"],
            "@exceptions/*": ["src/exceptions/*"],
            "@interfaces/*": ["src/interfaces/*"],
            "@middlewares/*": ["src/middlewares/*"],
            "@models/*": ["src/models/*"],
            "@routes/*": ["src/routes/*"],
            "@services/*": ["src/services/*"],
            "@utils/*": ["src/utils/*"],
            "@dtos/*": ["src/dtos/*"],
            "@daos/*": ["src/daos/*"],
            "@repositories/*": ["src/repositories/*"],
            "@databases/*": ["src/databases/*"],
            "@caches/*": ["src/caches/*"],
            "@loaders/*": ["src/loaders/*"],
            "@factories/*": ["src/factories/*"],
            "@mappers/*": ["src/mappers/*"],
            "@config": ["src/config"]
        }
    },
    "include": ["src/**/*"],
    "exclude": ["node_modules", "src/logs"]
}
```

**의존성 버전 주의 (Task 3에서 확인)**: `package-lock.json`을 제외하고 fresh pnpm install하면 floating `^` 범위가 최신 버전으로 올라가 타입 비호환이 생길 수 있다. 빌드가 타입 에러로 실패하면, 원본 `LeagueOfPhysical-MatchmakingServer/MatchmakingServer/package-lock.json`이 잠갔던 버전으로 해당 패키지를 핀 고정한다 (예: mongoose/mongodb/redis/class-transformer/@types/*). 임의 버전이 아니라 원본이 실제로 쓰던 버전으로.

- [ ] **Step 4: import 치환**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend/apps/matchmaking-server
grep -rl "@prisma/client" src | xargs sed -i '' "s|'@prisma/client'|'@lop/database'|g"
grep -rn "@prisma/client" src && echo "잔여 있음" || echo OK
```

- [ ] **Step 5: 빌드 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend && pnpm install && pnpm --filter matchmaking-server build
```
Expected: PASS (matchmaking은 Match/MatchmakingTicket/WaitingRoom 모델 사용 — 통합 스키마에 있음).

- [ ] **Step 6: 부팅 스모크** — `cd apps/matchmaking-server && NODE_ENV=development node dist/main`, 리슨 로그 확인.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: migrate matchmaking-server into monorepo"
```

---

### Task 5: room-server 이관

**Files:**
- Create: `apps/room-server/` (원본 `LeagueOfPhysical-RoomServer/RoomServer/`. `routes/` 포함, `server_binary/`·`dist/`·`node_modules/` 제외)
- Modify: 동일 파일 3종

**Interfaces:**
- Consumes: `@lop/database`
- Produces: `pnpm --filter room-server build/start`

- [ ] **Step 1: 복사**

```bash
cd /Users/insoobae/workspace/LOP
rsync -a --exclude node_modules --exclude dist --exclude prisma --exclude k8s \
  --exclude scripts --exclude Dockerfile --exclude package-lock.json --exclude server_binary \
  LeagueOfPhysical-RoomServer/RoomServer/ lop-backend/apps/room-server/
```

- [ ] **Step 2: package.json 수정** — `@prisma/client`·`prisma` 제거, `"@lop/database": "workspace:*"` 추가. (`@kubernetes/client-node`, `portfinder` 등 room 고유 deps는 그대로.)

- [ ] **Step 3: tsconfig.json을 base 상속으로 교체** (room은 `@schedulers` path가 하나 더 있음). **`outDir: "dist"` 명시 필수** (Task 3에서 확인 — base의 outDir은 루트 기준으로 해석됨):

```json
{
    "extends": "../../tsconfig.base.json",
    "compilerOptions": {
        "outDir": "dist",
        "baseUrl": ".",
        "paths": {
            "@src/*": ["src/*"],
            "@controllers/*": ["src/controllers/*"],
            "@exceptions/*": ["src/exceptions/*"],
            "@interfaces/*": ["src/interfaces/*"],
            "@middlewares/*": ["src/middlewares/*"],
            "@models/*": ["src/models/*"],
            "@routes/*": ["src/routes/*"],
            "@services/*": ["src/services/*"],
            "@utils/*": ["src/utils/*"],
            "@dtos/*": ["src/dtos/*"],
            "@daos/*": ["src/daos/*"],
            "@repositories/*": ["src/repositories/*"],
            "@databases/*": ["src/databases/*"],
            "@caches/*": ["src/caches/*"],
            "@loaders/*": ["src/loaders/*"],
            "@factories/*": ["src/factories/*"],
            "@mappers/*": ["src/mappers/*"],
            "@schedulers/*": ["src/schedulers/*"],
            "@config": ["src/config"]
        }
    },
    "include": ["src/**/*"],
    "exclude": ["node_modules", "src/logs"]
}
```

**의존성 버전 주의 (Task 3에서 확인)**: `package-lock.json` 제외 후 fresh pnpm install 시 floating `^` 범위가 타입 비호환 최신 버전으로 올라갈 수 있다. 빌드가 타입 에러로 실패하면 원본 `LeagueOfPhysical-RoomServer/RoomServer/package-lock.json`이 잠갔던 버전으로 핀 고정한다.

- [ ] **Step 4: import 치환**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend/apps/room-server
grep -rl "@prisma/client" src | xargs sed -i '' "s|'@prisma/client'|'@lop/database'|g"
grep -rn "@prisma/client" src && echo "잔여 있음" || echo OK
```

- [ ] **Step 5: 빌드 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend && pnpm install && pnpm --filter room-server build
```
Expected: PASS (room은 Room/RoomStatus 모델 사용 — 통합 스키마에 있음).

- [ ] **Step 6: 부팅 스모크** — `cd apps/room-server && NODE_ENV=development node dist/main`. room-server는 k8s API 클라이언트를 초기화하므로 kubeconfig 관련 로그가 나올 수 있음 — 리슨 로그 또는 명시적 k8s/DB 연결 에러까지 확인되면 통과.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: migrate room-server into monorepo"
```

---

### Task 6: Dockerfile 4종 (앱 3 + db-migrate)

**Files:**
- Create: `apps/lobby-server/Dockerfile`, `apps/matchmaking-server/Dockerfile`, `apps/room-server/Dockerfile`, `packages/database/Dockerfile`, `.dockerignore`(루트)

**Interfaces:**
- Consumes: Task 1~5의 workspace 구조
- Produces: 루트 컨텍스트로 빌드되는 이미지 4종. Phase 2 워크플로가 `docker build -f apps/<app>/Dockerfile .` 형태로 사용. 이미지 이름은 Phase 2에서 `re5nardo/<app>-server:<sha>`, `re5nardo/lop-db-migrate:<sha>`.

- [ ] **Step 1: 루트 `.dockerignore`**

```
**/node_modules
**/dist
**/generated
**/.turbo
**/logs
.git
```

- [ ] **Step 2: `apps/lobby-server/Dockerfile`**

```dockerfile
# 빌드 컨텍스트는 workspace 루트: docker build -f apps/lobby-server/Dockerfile .
FROM node:22 AS builder
RUN corepack enable
WORKDIR /repo
# prisma generate는 DB에 접속하진 않지만 datasource가 참조하는 env var가 정의돼 있어야 함.
# .env는 gitignore되어 빌드 컨텍스트에 없으므로 빌드 전용 placeholder를 주입 (런타임엔 앱이 자체 datasource url로 덮어씀).
ENV DATABASE_URL="postgresql://placeholder:placeholder@localhost:5432/placeholder?schema=public"
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json turbo.json tsconfig.base.json ./
COPY packages/database ./packages/database
COPY apps/lobby-server ./apps/lobby-server
RUN pnpm install --frozen-lockfile --filter lobby-server...
RUN pnpm --filter @lop/database run generate
RUN pnpm --filter lobby-server run build
# 해당 앱 + 프로덕션 의존성만 /out으로 추출
RUN pnpm --filter lobby-server deploy --prod --legacy /out

FROM node:22
ENV NODE_ENV=development
ENV SPECIFIC_ENV=local-k8s
WORKDIR /usr/src/lobby-server
COPY --from=builder /out ./
EXPOSE 80
CMD ["node", "dist/main.js"]
```

- [ ] **Step 3: `apps/matchmaking-server/Dockerfile`**

```dockerfile
FROM node:22 AS builder
RUN corepack enable
WORKDIR /repo
ENV DATABASE_URL="postgresql://placeholder:placeholder@localhost:5432/placeholder?schema=public"
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json turbo.json tsconfig.base.json ./
COPY packages/database ./packages/database
COPY apps/matchmaking-server ./apps/matchmaking-server
RUN pnpm install --frozen-lockfile --filter matchmaking-server...
RUN pnpm --filter @lop/database run generate
RUN pnpm --filter matchmaking-server run build
RUN pnpm --filter matchmaking-server deploy --prod --legacy /out

FROM node:22
ENV NODE_ENV=development
ENV SPECIFIC_ENV=local-k8s
WORKDIR /usr/src/matchmaking-server
COPY --from=builder /out ./
EXPOSE 80
CMD ["node", "dist/main.js"]
```

- [ ] **Step 4: `apps/room-server/Dockerfile`**

```dockerfile
FROM node:22 AS builder
RUN corepack enable
WORKDIR /repo
ENV DATABASE_URL="postgresql://placeholder:placeholder@localhost:5432/placeholder?schema=public"
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json turbo.json tsconfig.base.json ./
COPY packages/database ./packages/database
COPY apps/room-server ./apps/room-server
RUN pnpm install --frozen-lockfile --filter room-server...
RUN pnpm --filter @lop/database run generate
RUN pnpm --filter room-server run build
RUN pnpm --filter room-server deploy --prod --legacy /out

FROM node:22
ENV NODE_ENV=development
ENV SPECIFIC_ENV=local-k8s
WORKDIR /usr/src/room-server
COPY --from=builder /out ./
EXPOSE 80
CMD ["node", "dist/main.js"]
```

- [ ] **Step 5: `packages/database/Dockerfile` (마이그레이션+seed Job용)**

```dockerfile
# docker build -f packages/database/Dockerfile .
# 런타임 DATABASE_URL은 Phase 1 PreSync Job이 주입. 빌드 시 generate용 placeholder는 아래 ENV.
FROM node:22
RUN corepack enable
WORKDIR /repo
# 빌드타임 generate 전용 placeholder (런타임엔 Job이 실제 DATABASE_URL로 덮어씀)
ENV DATABASE_URL="postgresql://placeholder:placeholder@localhost:5432/placeholder?schema=public"
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY packages/database ./packages/database
RUN pnpm install --frozen-lockfile --filter @lop/database
WORKDIR /repo/packages/database
RUN pnpm run generate
CMD ["sh", "-c", "pnpm run migrate:deploy && pnpm run seed"]
```

- [ ] **Step 6: 빌드 검증 (4종 전부)**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
docker build -f apps/lobby-server/Dockerfile -t lop-test/lobby .
docker build -f apps/matchmaking-server/Dockerfile -t lop-test/matchmaking .
docker build -f apps/room-server/Dockerfile -t lop-test/room .
docker build -f packages/database/Dockerfile -t lop-test/db-migrate .
docker run --rm lop-test/lobby node -e "console.log(require('fs').existsSync('dist/main.js'))"
```
Expected: 4개 모두 빌드 성공, 마지막 명령 `true` 출력.
알려진 리스크: `pnpm deploy`가 pnpm 10에서 `--legacy` 플래그를 요구함(이미 반영). deploy 산출물에 `@lop/database`의 `generated/`가 포함되는지 `docker run --rm lop-test/lobby ls node_modules/@lop/database/generated/client`로 확인 — 없으면 deploy 단계 전에 `RUN cp -R` 백업 방식으로 전환하고 커밋 메시지에 기록.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: add root-context Dockerfiles (pnpm deploy pattern) for 3 apps + db-migrate"
```

---

### Task 7: README + 최종 통합 검증

**Files:**
- Create: `README.md`(루트)

**Interfaces:**
- Produces: 클린 체크아웃 기준 전체 빌드 재현성 보장.

- [ ] **Step 1: README.md 작성**

```markdown
# lop-backend

League of Physical 백엔드 모노레포. lobby/matchmaking/room 서버와 DB 스키마 패키지를 관리한다.
(구 LeagueOfPhysical-LobbyServer / -MatchmakingServer / -RoomServer / db-admin 레포 통합, 2026-07)

## 구조
- `apps/lobby-server` — 인증/로비 API
- `apps/matchmaking-server` — 매치메이킹
- `apps/room-server` — 매치 오케스트레이터 (Unity game-server 파드 동적 생성)
- `packages/database` — Prisma 스키마 단일 소유자 (구 db-admin). 마이그레이션 + seed 포함

## 명령
- `pnpm install` — 전체 의존성 설치
- `pnpm build` — 전체 빌드 (turbo, @lop/database generate 포함)
- `pnpm --filter <app> build|start` — 개별 앱
- `pnpm --filter @lop/database migrate:dev|seed` — DB 작업 (DATABASE_URL 필요)

## 도커
빌드 컨텍스트는 반드시 레포 루트:
`docker build -f apps/lobby-server/Dockerfile .`

## 배포
infrastructure 레포의 k8s 매니페스트 + ArgoCD가 담당.
설계: infrastructure/docs/specs/2026-07-05-deployment-system-design.md
```

- [ ] **Step 2: 클린 재현성 검증**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
# .superpowers는 진행 레저/리뷰 산출물이므로 반드시 보존 (-e). env 파일은 git 추적 중이라 어차피 안 지워짐.
git clean -xdf -e .superpowers --dry-run   # 삭제 대상 확인 — .superpowers가 목록에 없어야 함
git clean -xdf -e .superpowers
pnpm install
pnpm build
```
Expected: `turbo run build` 4개 패키지 전부 성공. dry-run 목록에 `.superpowers/`와 `.env.development.local*`(git 추적됨)가 없어야 함.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "docs: add monorepo README"
```

---

### Task 8: GitHub 레포 생성 + push

**Files:** 없음 (원격 작업)

- [ ] **Step 1: 레포 생성 및 push**

```bash
cd /Users/insoobae/workspace/LOP/lop-backend
gh repo create Baeinsoo/lop-backend --private --source . --remote origin --push
```
Expected: push 성공. (`gh` 미인증 시 `gh auth login` 안내 — 사용자에게 `! gh auth login` 실행 요청)

- [ ] **Step 2: 확인**

```bash
gh repo view Baeinsoo/lop-backend --json name,visibility,defaultBranchRef
```
Expected: name=lop-backend, private.

- [ ] **Step 3: 기존 레포는 건드리지 않음을 확인**

원본 4개 레포(LobbyServer/MatchmakingServer/RoomServer/db-admin)의 archive는 **Phase 2 완료 후** (워크플로가 실제로 모노레포 기준으로 도는 걸 확인한 뒤) 별도 수행. 이 시점에는 아무 것도 하지 않는다.

---

## 완료 기준 (스펙 Phase 0 검증 항목)

1. `pnpm build`가 클린 체크아웃에서 통과
2. 3개 서버가 로컬에서 부팅 (DB 연결 포함)
3. 도커 이미지 4종 빌드 성공
4. Prisma 스키마가 `packages/database` 한 곳에만 존재하고 3개 앱이 `@lop/database`를 import
