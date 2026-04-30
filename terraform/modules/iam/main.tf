variable "project" {}
variable "environment" {}
variable "eks_cluster_name" {}
variable "oidc_issuer_url" {}
variable "oidc_provider_arn" {}
variable "github_org" {
  description = "GitHub username or org that owns the repository"
  default     = "gpelipas"
}

locals {
  name         = "${var.project}-${var.environment}"
  oidc_sub     = "${replace(var.oidc_issuer_url, "https://", "")}:sub"
  oidc_aud     = "${replace(var.oidc_issuer_url, "https://", "")}:aud"
  namespace    = "prod"
  sa_name      = "url-shortener-sa"
}

# IRSA role — trusted by the Kubernetes service account in the app namespace
resource "aws_iam_role" "app" {
  name = "${local.name}-app-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_sub}" = "system:serviceaccount:${local.namespace}:${local.sa_name}"
          "${local.oidc_aud}" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Allow the app to read its DB credentials from Secrets Manager
resource "aws_iam_policy" "app" {
  name = "${local.name}-app-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:${local.name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app.arn
}

# GitHub Actions deploy role (OIDC trust for CI/CD)
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "github_actions" {
  name = "${local.name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.project}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_policy" "github_eks" {
  name = "${local.name}-github-eks-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_eks" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_eks.arn
}

output "app_role_arn"            { value = aws_iam_role.app.arn }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }

# AWS Load Balancer Controller IAM policy
data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${local.name}-alb-controller-policy"
  policy = data.http.alb_controller_policy.response_body
}

# AWS Load Balancer Controller IRSA role
resource "aws_iam_role" "alb_controller" {
  name = "${local.name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_sub}" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_aud}" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
