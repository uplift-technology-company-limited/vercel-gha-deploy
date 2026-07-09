# AWS ECS (Fargate + ECR) — deploy shape

For a service that runs as a long-lived container behind ECS — the same shape
`sanoe_pos_web` and other Uplift backend/frontend services already use in
production.

## 0. Confirm the registry exists (read-only, always safe)

```bash
aws ecr describe-repositories --repository-names <service> --region <region>
```

If this errors with `RepositoryNotFoundException`, **stop** — see SKILL.md
Step 5. This reference assumes the ECR repo already exists.

## 1. Dockerfile — multi-stage, arm64-friendly

```dockerfile
# syntax=docker/dockerfile:1.4
FROM oven/bun:1.3 AS base       # or node:22-alpine, whatever the service uses
WORKDIR /app

FROM base AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Version (git tag vX.Y.Z) — baked in by upliftcontrolversion's compute_version,
# passed as a build-arg if this is a frontend (see that skill's frontend-nextjs.md).
ARG NEXT_PUBLIC_APP_VERSION
ENV NEXT_PUBLIC_APP_VERSION=${NEXT_PUBLIC_APP_VERSION}
RUN bun run build

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup --system --gid 1001 appuser && adduser --system --uid 1001 appuser
COPY --from=builder --chown=appuser:appuser /app/.next/standalone ./   # or your build output
USER appuser
EXPOSE 3000
ENV PORT=3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode===200?0:1))"
CMD ["node", "server.js"]
```

For a pure backend (no `NEXT_PUBLIC_*` build-arg), drop the `ARG`/`ENV` pair
in the builder stage — `upliftcontrolversion`'s backend shape injects
`APP_VERSION` at **runtime** via the task-def env instead, no rebuild needed.

## 2. `scripts/deploy.sh` — build → push → register → roll out

```bash
#!/usr/bin/env bash
set -euo pipefail

AWS_ACCOUNT="<account-id>"
REGION="<region>"                 # e.g. ap-southeast-1
ECR_REPO="${AWS_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/<service>"
ECS_CLUSTER="<cluster>"
ECS_SERVICE="<service>"
IMAGE_TAG="$(git rev-parse --short HEAD)"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

docker build \
  --build-arg NEXT_PUBLIC_APP_VERSION="${APP_VERSION:-}" \
  -t "${ECR_REPO}:${IMAGE_TAG}" .
docker push "${ECR_REPO}:${IMAGE_TAG}"

# Describe the live task-def, patch the image (and APP_VERSION/OTEL_SERVICE_VERSION
# if upliftcontrolversion wired those in — see that skill's SKILL.md Step 1), register
# a new revision, then point the service at it.
aws ecs describe-task-definition --task-definition "$ECS_SERVICE" --region "$REGION" \
  --query 'taskDefinition' > task-def.json

jq --arg IMG "${ECR_REPO}:${IMAGE_TAG}" \
  'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
   | .containerDefinitions[0].image = $IMG' \
  task-def.json > task-def.new.json

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --region "$REGION" \
  --cli-input-json file://task-def.new.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)

aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$NEW_TASK_DEF_ARN" --force-new-deployment --region "$REGION"

aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$REGION"
echo "✓ Deployed ${ECR_REPO}:${IMAGE_TAG}"
```

Where `upliftcontrolversion` plugs in: its `compute_version` runs *before*
`docker build` (so `APP_VERSION` exists for the build-arg), and its jq upsert
for `APP_VERSION`/`OTEL_SERVICE_VERSION` extends the same `jq` patch shown
above — see that skill's `references/gha.md` for the exact upsert expression.
Don't duplicate that logic here; just make sure this script calls
`compute_version` first and leaves room in the jq for those two env vars.

## 3. GHA workflow shape

Same skeleton as [assets/deploy-ecs.yml](../assets/deploy-ecs.yml) — typecheck
gate → `scripts/deploy.sh` → smoke test, guarded to `main`, first run as
`workflow_dispatch`. If self-hosted, the build is native arm64 (no QEMU); if
GitHub-hosted, either accept the emulation cost or build a Fargate-compatible
x86 image instead.

## Verify

```bash
aws ecs describe-services --cluster <cluster> --services <service> --region <region> \
  --query 'services[0].deployments[0].rolloutState'   # -> COMPLETED
curl -s https://<service-host>/health
```

Plus whatever `upliftcontrolversion`'s own verify steps check for the backend
shape (`/version`, `OTEL_SERVICE_VERSION` on the live task-def).
