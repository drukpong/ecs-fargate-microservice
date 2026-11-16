# Containerized Microservice on ECS Fargate

A Node.js API packaged with a multi-stage Dockerfile, pushed to a private ECR
registry, and run on **ECS Fargate** behind an **Application Load Balancer**.
All infrastructure is Terraform; deploys run from GitHub Actions with a
**dev -> staging** matrix. No servers to patch, no static AWS keys.

```
                  Internet
                     |
              +------v------+        public subnets (2 AZs)
              |     ALB     |
              +------+------+
                     | :3000  (SG: only from ALB)
   +-----------------v------------------+   private subnets (2 AZs)
   |  Fargate tasks  (autoscaling 1-N)  |---> NAT GW ---> ECR / CloudWatch
   +------------------------------------+
```

## Repo layout

| Path | What it is |
|---|---|
| `app/` | Zero-dependency Node.js API, tests, multi-stage `Dockerfile` |
| `terraform/` | VPC, ECR, ALB, ECS (cluster/task/service), IAM, autoscaling |
| `terraform/envs/*.tfvars` | Per-environment sizing (dev is small, staging is larger) |
| `.github/workflows/deploy.yml` | Test -> matrix deploy (dev, then staging) |
| `scripts/` | `bootstrap-state.sh`, `smoke-test.sh`, `load-test.sh` |

## API

| Route | Purpose |
|---|---|
| `GET /health` | ALB / container health check |
| `GET /` | Service name, environment, version (git SHA) |
| `GET/POST /api/items` | Tiny in-memory CRUD example |
| `GET /api/work?ms=50` | Burns CPU for N ms - used to trigger autoscaling |

## Run locally

```bash
cd app && npm test && npm start            # http://localhost:3000
docker build --target runtime -t ecs-api ./app
docker run --rm -p 3000:3000 ecs-api
```

## One-time AWS setup

1. **State bucket**: `./scripts/bootstrap-state.sh my-unique-tfstate-bucket us-east-1`
2. **GitHub OIDC provider** in IAM (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`).
3. **One IAM role per environment** trusting your repo, e.g. for dev:
   ```json
   {
     "Effect": "Allow",
     "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
     "Action": "sts:AssumeRoleWithWebIdentity",
     "Condition": {
       "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
       "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:environment:dev" }
     }
   }
   ```
   For a sandbox account, attach `AdministratorAccess` to get going; for anything
   real, scope it to EC2/VPC, ECS, ECR, ELB, IAM (role create/pass), Logs,
   Application Auto Scaling, and the state bucket.
4. **GitHub settings** -> Environments: create `dev` and `staging`.
   - Secret `AWS_ROLE_ARN` in each environment (that environment's role).
   - Add *required reviewers* to `staging` for a manual promotion gate.
5. **GitHub settings** -> Variables: `TF_STATE_BUCKET`, and optionally `AWS_REGION` (default `us-east-1`).

Push to `main` and watch the Actions tab. The job summary prints each URL.

## How the pipeline works

1. **test**: unit tests, `shellcheck`, `terraform fmt -check` + `validate` (runs on PRs too).
2. **deploy (matrix: dev, staging)**, `max-parallel: 1`, `fail-fast: true`:
   1. `terraform init` with a **per-env state key** (`<repo>/dev.tfstate`, `<repo>/staging.tfstate`)
   2. Create the ECR repo only (`-target`) so there is somewhere to push
   3. Build and push `:<git-sha>` (skipped if that tag exists; tags are immutable)
   4. Full `terraform apply` with `image_tag=<git-sha>` -> new task definition revision
   5. `aws ecs wait services-stable`, then smoke test (and a short load test on dev)

Rollback safety: the ECS **deployment circuit breaker** auto-rolls back if new
tasks never become healthy. To roll back manually, re-run the workflow on an older commit.

## Load testing

```bash
URL=$(cd terraform && terraform output -raw app_url)

./scripts/load-test.sh -u "$URL"                                  # light: /health
./scripts/load-test.sh -u "$URL" -p "/api/work?ms=100" -n 5000 -c 50   # trigger autoscaling
```

Exit codes make it CI-friendly: `2` = error rate over `-e`, `3` = p95 over `-l`.
Watch scale-out in the ECS console (Service -> Tasks) or CloudWatch Container Insights;
scale-out reacts within a minute or two, scale-in after about 2+ minutes of low load.

## Manual deploy (without CI)

```bash
cd terraform
terraform init -backend-config="bucket=<bucket>" -backend-config="key=ecs-api/dev.tfstate" -backend-config="region=us-east-1"
terraform apply -target=aws_ecr_repository.app -var-file=envs/dev.tfvars
# build + push an image tagged $TAG to $(terraform output -raw ecr_repository_url), then:
terraform apply -var-file=envs/dev.tfvars -var="image_tag=$TAG"
```

## Cost notes (us-east-1, rough)

ALB ~ $16/mo + NAT gateway ~ $32/mo + Fargate (0.25 vCPU / 0.5 GB x 1 task) ~ $9/mo per environment.
**Tear down when not in use:** `terraform destroy -var-file=envs/dev.tfvars` (dev ECR repos are force-deleted).

## Production hardening (next steps)

- HTTPS: ACM certificate + `:443` listener, redirect `:80`, Route 53 alias
- NAT per AZ or VPC endpoints (ECR, S3, Logs) for HA / lower NAT cost
- Secrets via Secrets Manager / SSM referenced in the task definition `secrets`
- A real datastore (RDS/DynamoDB) - the in-memory items endpoint is a demo
- CloudWatch alarms (5xx, unhealthy hosts, CPU) + WAF on the ALB
- `terraform plan` as a PR comment; separate AWS accounts per environment
