# AWS EKS SPRINGBOOT PROJECT

Basic URL shortner application built using the ff. tech stacks: **EKS, Spring Boot, RDS PostgreSQL, API Gateway, Terraform, Helm, and GitHub Actions**.

## Stack

| Layer       | Technology                              |
|-------------|------------------------------------------|
| Compute     | AWS EKS (managed Kubernetes)            |
| App         | Spring Boot 3.2 / Java 21               |
| Database    | RDS PostgreSQL 16 + Flyway migrations   |
| Registry    | Amazon ECR                              |
| Networking  | VPC, ALB Ingress, API Gateway           |
| IaC         | Terraform (modular)                     |
| Packaging   | Helm 3                                  |
| CI/CD       | GitHub Actions (OIDC, no static keys)   |
| Secrets     | AWS Secrets Manager + IRSA              |

## Project Structure

```
url-shortener/
├── src/                        # Spring Boot application
├── terraform/
│   ├── main.tf                 # Root module wiring
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── vpc/                # VPC, subnets, NAT gateways
│       ├── eks/                # EKS cluster + OIDC provider
│       ├── rds/                # RDS Postgres + Secrets Manager
│       ├── ecr/                # ECR repo + lifecycle policy
│       └── iam/                # IRSA role + GitHub Actions OIDC role
├── helm/url-shortener/         # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml        # ALB annotations
│       ├── hpa.yaml            # CPU + memory autoscaling
│       ├── serviceaccount.yaml # IRSA-annotated SA
│       ├── secret.yaml
│       └── pdb.yaml            # PodDisruptionBudget
└── .github/workflows/
    ├── ci.yml                  # Test + Terraform/Helm lint on PR
    └── deploy.yml              # Build → ECR push → Helm deploy on merge
```

## API Endpoints

| Method | Path              | Description                      |
|--------|-------------------|----------------------------------|
| POST   | /api/shorten      | Create a short URL               |
| GET    | /{code}           | Redirect to original URL         |
| GET    | /api/stats/{code} | Click count and metadata         |
| GET    | /health           | Liveness / readiness probe       |

**POST /api/shorten**
```json
{
  "url": "https://example.com/very/long/path",
  "ttlDays": 30
}
```

## Getting Started

### 1 — Provision infrastructure
```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 2 — Configure GitHub secrets
| Secret              | Value                                  |
|---------------------|----------------------------------------|
| AWS_DEPLOY_ROLE_ARN | ARN from `terraform output github_actions_role_arn` |
| ECR_REGISTRY        | AWS account ECR registry URL           |
| IRSA_ROLE_ARN       | ARN from `terraform output irsa_role_arn` |
| DB_URL              | RDS JDBC URL                           |
| DB_USERNAME         | DB username                            |
| DB_PASSWORD         | DB password                            |

### 3 — Deploy
Push to `main` → GitHub Actions builds, pushes to ECR, and deploys via Helm automatically.

### 4 — Manual Helm deploy (local)
```bash
aws eks update-kubeconfig --name url-shortener-prod-cluster --region us-east-1

helm upgrade --install prod ./helm/url-shortener \
  --namespace prod --create-namespace \
  --set image.repository=<ECR_URL> \
  --set image.tag=latest \
  --wait
```

## Key AWS Concepts Demonstrated

- **IRSA** — IAM Roles for Service Accounts (pod-level least-privilege)
- **OIDC GitHub Actions** — keyless CI/CD auth, no static IAM credentials stored
- **HPA** — Horizontal Pod Autoscaler on CPU + memory metrics
- **PodDisruptionBudget** — guarantees availability during node upgrades
- **Flyway** — version-controlled DB schema migrations
- **Secrets Manager** — DB credentials injected at runtime, not baked into images
- **ECR lifecycle policy** — automatic cleanup of old images
