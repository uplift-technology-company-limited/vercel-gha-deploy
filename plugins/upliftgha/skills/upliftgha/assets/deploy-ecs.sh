#!/usr/bin/env bash
# Deploy <SERVICE_NAME> to ECS: build → push to ECR → register task-def →
# roll out → wait stable. Version tagging (compute_version/tag_release) is
# upliftcontrolversion's contract — wire it in per that skill's SKILL.md
# rather than reinventing it here; this script just needs to call
# compute_version before `docker build` and tag_release after a stable
# rollout, same as every other Uplift deploy.sh.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

AWS_ACCOUNT="<account-id>"
REGION="<region>"
SERVICE_NAME="<service>"
ECR_REPO="${AWS_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${SERVICE_NAME}"
ECS_CLUSTER="<cluster>"
ECS_SERVICE="<service>"

BUMP="${BUMP:-patch}"
IMAGE_TAG="$(git rev-parse --short HEAD)"
RELEASE_TAG=""
APP_VERSION=""

# --- version (upliftcontrolversion contract; keep in sync with that skill) ---
compute_version() {
  git fetch --tags --quiet origin 2>/dev/null || true
  local latest major minor patch
  latest="$(git tag --list 'v*' | sort -V | tail -n1)"
  latest="${latest:-v0.0.0}"
  IFS='.' read -r major minor patch <<< "${latest#v}"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  case "$BUMP" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    *)     patch=$((patch + 1)) ;;
  esac
  RELEASE_TAG="v${major}.${minor}.${patch}"
  while git rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; do
    patch=$((patch + 1)); RELEASE_TAG="v${major}.${minor}.${patch}"
  done
  APP_VERSION="${RELEASE_TAG#v}"
  echo "Version: ${RELEASE_TAG} (bump=${BUMP})" >&2
}

tag_release() {
  [ -n "$RELEASE_TAG" ] || return 0
  git config user.name  >/dev/null 2>&1 || git config user.name  "ci-deploy"
  git config user.email >/dev/null 2>&1 || git config user.email "deploy@example.com"
  git tag -a "$RELEASE_TAG" -m "$RELEASE_TAG — automated ECS deploy (${IMAGE_TAG})" 2>/dev/null || true
  git push origin "$RELEASE_TAG" 2>/dev/null && echo "Tagged ${RELEASE_TAG}" >&2 \
    || echo "Could not push tag ${RELEASE_TAG} (non-fatal)" >&2
}

deploy() {
  compute_version

  echo "→ ECR login…"
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

  echo "→ Building ${ECR_REPO}:${IMAGE_TAG} (APP_VERSION=${APP_VERSION})…"
  docker build \
    --build-arg NEXT_PUBLIC_APP_VERSION="${APP_VERSION}" \
    -t "${ECR_REPO}:${IMAGE_TAG}" .
  docker push "${ECR_REPO}:${IMAGE_TAG}"

  echo "→ Registering new task-def revision…"
  aws ecs describe-task-definition --task-definition "$ECS_SERVICE" --region "$REGION" \
    --query 'taskDefinition' > task-def.json

  # Upsert APP_VERSION + OTEL_SERVICE_VERSION alongside the image — this is
  # the integration point with upliftcontrolversion's backend shape.
  jq --arg IMG "${ECR_REPO}:${IMAGE_TAG}" --arg VER "${APP_VERSION}" \
    'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
     | .containerDefinitions[0].image = $IMG
     | .containerDefinitions[0].environment = ((.containerDefinitions[0].environment // [])
         | map(select(.name != "APP_VERSION" and .name != "OTEL_SERVICE_VERSION"))
         + [{name: "APP_VERSION", value: $VER}, {name: "OTEL_SERVICE_VERSION", value: $VER}])' \
    task-def.json > task-def.new.json

  NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --region "$REGION" \
    --cli-input-json file://task-def.new.json \
    --query 'taskDefinition.taskDefinitionArn' --output text)

  echo "→ Rolling out ${NEW_TASK_DEF_ARN}…"
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
    --task-definition "$NEW_TASK_DEF_ARN" --force-new-deployment --region "$REGION" >/dev/null

  aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$REGION"

  tag_release
  echo "✓ Deployed ${SERVICE_NAME} ${RELEASE_TAG} (${ECR_REPO}:${IMAGE_TAG})"
}

case "${1:-}" in
  deploy) deploy ;;
  *) echo "usage: $0 deploy"; exit 1 ;;
esac
