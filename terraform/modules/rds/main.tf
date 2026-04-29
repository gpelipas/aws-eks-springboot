variable "project" {}
variable "environment" {}
variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "eks_sg_id" {}
variable "db_name" {}
variable "instance_class" {}
variable "postgres_version" {}

locals {
  name = "${var.project}-${var.environment}"
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${local.name}/rds/credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "appuser"
    password = random_password.db.result
    dbname   = var.db_name
    host     = aws_db_instance.main.address
    port     = 5432
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${local.name}-db-subnet-group" }
}

resource "aws_security_group" "rds" {
  name   = "${local.name}-rds-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_sg_id]
    description     = "Allow EKS nodes to reach RDS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-rds-sg" }
}

resource "aws_db_instance" "main" {
  identifier              = "${local.name}-postgres"
  engine                  = "postgres"
  engine_version          = var.postgres_version
  instance_class          = var.instance_class
  allocated_storage       = 20
  max_allocated_storage   = 100
  storage_encrypted       = true

  db_name  = var.db_name
  username = "appuser"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = false   # Set true for production HA
  publicly_accessible    = false
  deletion_protection    = false   # Set true for production
  skip_final_snapshot    = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  tags = { Name = "${local.name}-postgres" }
}

output "endpoint"       { value = aws_db_instance.main.address  sensitive = true }
output "secret_arn"     { value = aws_secretsmanager_secret.db_credentials.arn }
output "db_sg_id"       { value = aws_security_group.rds.id }
