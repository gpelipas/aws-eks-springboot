terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "awsdad-url-shortener-tfstate"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "awsdad-url-shortener-tflock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "url-shortener"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

module "vpc" {
  source             = "./modules/vpc"
  project            = var.project
  environment        = var.environment
  cidr               = "10.0.0.0/16"
  availability_zones = ["${var.aws_region}a", "${var.aws_region}b"]
}

module "ecr" {
  source      = "./modules/ecr"
  project     = var.project
  environment = var.environment
}

module "eks" {
  source           = "./modules/eks"
  project          = var.project
  environment      = var.environment
  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnet_ids
  cluster_version  = "1.30"
  node_instance_type = var.eks_node_instance_type
  node_min         = 1
  node_max         = 4
  node_desired     = 2
}

module "rds" {
  source          = "./modules/rds"
  project         = var.project
  environment     = var.environment
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
  eks_sg_id       = module.eks.node_security_group_id
  db_name         = "urlshortener"
  instance_class  = var.rds_instance_class
  postgres_version = "16.13"
}

module "iam" {
  source           = "./modules/iam"
  project          = var.project
  environment      = var.environment
  eks_cluster_name = module.eks.cluster_name
  oidc_issuer_url  = module.eks.oidc_issuer_url
  oidc_provider_arn = module.eks.oidc_provider_arn
}

# --- Helm provider for installing Kubernetes apps via Terraform ---
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

# --- AWS Load Balancer Controller ---
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.11.0"

  depends_on = [
    module.eks,
    module.iam
  ]

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.iam.alb_controller_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
}
