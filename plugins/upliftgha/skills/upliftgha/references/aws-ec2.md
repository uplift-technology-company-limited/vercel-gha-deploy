# AWS EC2 (docker-compose) — deploy shape

For a service that lives on a persistent EC2 instance, run via
`docker-compose` — the pattern Uplift already uses for compose-on-EC2 stacks
(e.g. monitoring). The **compose file is the source of truth**; the deploy
step's whole job is: get the latest compose file + images onto the box, and
recreate the containers.

## Prefer SSM over SSH

`aws ssm send-command` runs a shell command on the instance without opening
port 22 or managing SSH keys in CI — the instance just needs the SSM agent
(standard on Amazon Linux 2023 / most current AMIs) and an instance profile
with `AmazonSSMManagedInstanceCore`. Use SSH only if the box genuinely can't
run the SSM agent.

## Two ways to get new code onto the box

Pick based on whether the runner builds the image or the box does:

- **Build-and-push, box just pulls** (matches the ECS shape, one Docker build
  location): CI builds the image, pushes to ECR, `docker-compose.yml` on the
  box references the ECR tag, the deploy step is `docker compose pull && up
  -d`. Preferred when the image is also used elsewhere, or the build needs
  more CPU/memory than a small EC2 box has spare.
- **Git pull + local build**: the box has its own clone of the repo, deploy
  step is `git pull && docker compose build && docker compose up -d`.
  Simpler (no registry needed at all), but the build competes with the
  running service for the box's own resources — fine for light services, not
  for anything CPU-heavy.

## `scripts/deploy.sh` — SSM version (build-and-push)

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="<region>"
INSTANCE_ID="<i-xxxxxxxxxxxxxxxxx>"
ECR_REPO="<account>.dkr.ecr.<region>.amazonaws.com/<service>"
IMAGE_TAG="$(git rev-parse --short HEAD)"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REPO"
docker build --build-arg NEXT_PUBLIC_APP_VERSION="${APP_VERSION:-}" -t "${ECR_REPO}:${IMAGE_TAG}" .
docker push "${ECR_REPO}:${IMAGE_TAG}"

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --region "$REGION" \
  --parameters commands="[
    \"aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REPO\",
    \"cd /opt/<service>\",
    \"sed -i 's|image: .*|image: ${ECR_REPO}:${IMAGE_TAG}|' docker-compose.yml\",
    \"docker compose pull\",
    \"docker compose up -d\",
    \"docker image prune -f\"
  ]" \
  --query 'Command.CommandId' --output text)

aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --region "$REGION"
echo "✓ Deployed ${ECR_REPO}:${IMAGE_TAG} to ${INSTANCE_ID}"
```

## `scripts/deploy.sh` — SSM version (git pull, no registry)

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="<region>"
INSTANCE_ID="<i-xxxxxxxxxxxxxxxxx>"

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --region "$REGION" \
  --parameters commands="[
    \"cd /opt/<service>\",
    \"git pull origin main\",
    \"docker compose build\",
    \"docker compose up -d\",
    \"docker image prune -f\"
  ]" \
  --query 'Command.CommandId' --output text)

aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --region "$REGION"
echo "✓ Pulled + redeployed on ${INSTANCE_ID}"
```

Either way, `upliftcontrolversion`'s `compute_version` runs before the build
(same as the ECS shape) and `tag_release` runs after the SSM command reports
success — the tag still only lands on a real, verified rollout.

## GHA workflow shape

Same skeleton as [assets/deploy-ec2.yml](../assets/deploy-ec2.yml) — the AWS
credentials the runner needs are `ecr:GetAuthorizationToken` +
`ecr:*Image*` (build-and-push variant) or nothing AWS-specific at all (git-pull
variant, only needs `ssm:SendCommand`/`ssm:GetCommandInvocation` either way).
Guarded to `main`, first run as `workflow_dispatch`, same as every other
shape.

## Verify

```bash
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters commands='["docker compose ps"]' --region <region>
curl -s https://<service-host>/health
```

If the box isn't directly reachable, `curl` through whatever's in front of it
(ALB, Cloudflare) instead of the instance's own address.
