#!/usr/bin/env bash
# Deploy <SERVICE_NAME> to an EC2 box via SSM (no SSH key management, no open
# port 22). Two variants below — delete whichever doesn't apply. See
# references/aws-ec2.md for when to pick which. Version tagging
# (compute_version/tag_release) is upliftcontrolversion's contract; this
# script just calls it before the build and after a verified rollout, same as
# every other Uplift deploy.sh.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

REGION="<region>"
INSTANCE_ID="<i-xxxxxxxxxxxxxxxxx>"
REMOTE_DIR="/opt/<service>"

BUMP="${BUMP:-patch}"
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
  git tag -a "$RELEASE_TAG" -m "$RELEASE_TAG — automated EC2 deploy" 2>/dev/null || true
  git push origin "$RELEASE_TAG" 2>/dev/null && echo "Tagged ${RELEASE_TAG}" >&2 \
    || echo "Could not push tag ${RELEASE_TAG} (non-fatal)" >&2
}

# Runs an SSM command on the box and waits for it to finish. Fails loudly if
# the command itself failed on the box (not just if send-command failed).
run_on_box() {
  local commands_json="$1"
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --region "$REGION" \
    --parameters commands="$commands_json" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$INSTANCE_ID" --region "$REGION"
}

# --- Variant A: build-and-push (CI builds, box just pulls) ------------------
deploy_build_and_push() {
  local account="<account-id>"
  local ecr_repo="${account}.dkr.ecr.${REGION}.amazonaws.com/<service>"
  local image_tag
  image_tag="$(git rev-parse --short HEAD)"

  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${account}.dkr.ecr.${REGION}.amazonaws.com"
  docker build --build-arg NEXT_PUBLIC_APP_VERSION="${APP_VERSION}" -t "${ecr_repo}:${image_tag}" .
  docker push "${ecr_repo}:${image_tag}"

  run_on_box "[
    \"aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${account}.dkr.ecr.${REGION}.amazonaws.com\",
    \"cd ${REMOTE_DIR}\",
    \"sed -i 's|image: .*|image: ${ecr_repo}:${image_tag}|' docker-compose.yml\",
    \"docker compose pull\",
    \"docker compose up -d\",
    \"docker image prune -f\"
  ]"
  echo "✓ Deployed ${ecr_repo}:${image_tag} to ${INSTANCE_ID}"
}

# --- Variant B: git pull + build on the box (no registry) -------------------
deploy_git_pull() {
  run_on_box "[
    \"cd ${REMOTE_DIR}\",
    \"git pull origin main\",
    \"APP_VERSION=${APP_VERSION} docker compose build\",
    \"APP_VERSION=${APP_VERSION} docker compose up -d\",
    \"docker image prune -f\"
  ]"
  echo "✓ Pulled + redeployed on ${INSTANCE_ID}"
}

deploy() {
  compute_version
  deploy_build_and_push   # or: deploy_git_pull — pick one, delete the other call
  tag_release
}

case "${1:-}" in
  deploy) deploy ;;
  *) echo "usage: $0 deploy"; exit 1 ;;
esac
