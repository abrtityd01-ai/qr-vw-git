terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  profile = "solser-dev"
}

########################
# Variables   SE ACTUALIZA AQUI
########################
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "qrcode"
}

variable "environment" {
  description = "Ambiente"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs para subnets públicas"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs para subnets privadas"
  type        = list(string)
  default     = ["10.10.11.0/24", "10.10.12.0/24"]
}

variable "allowed_mysql_cidr" {
  description = "CIDR permitido para acceso MySQL (DEV)"
  type        = string
  # cámbialo a tu IP /32
  default     = "0.0.0.0/0"
}

variable "db_name" {
  description = "Nombre de base de datos inicial"
  type        = string
  default     = "qrcode"
}

variable "db_master_username" {
  description = "Usuario administrador"
  type        = string
  default     = "admin"
}

########################
# Locals
########################
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

########################
# VPC
########################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

########################
# Subnets
########################
resource "aws_subnet" "public" {
  for_each = {
    az1 = var.public_subnet_cidrs[0]
    az2 = var.public_subnet_cidrs[1]
  }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}${each.key == "az1" ? "a" : "b"}"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = {
    az1 = var.private_subnet_cidrs[0]
    az2 = var.private_subnet_cidrs[1]
  }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key == "az1" ? "a" : "b"}"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-${each.key}"
    Tier = "private"
  })
}

########################
# Route Tables
########################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

########################
# NAT Gateway (para privadas)
########################
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip"
  })
}

resource "aws_nat_gateway" "this" {
  subnet_id     = values(aws_subnet.public)[0].id
  allocation_id = aws_eip.nat.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rt"
  })
}

resource "aws_route" "private_to_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

########################
# Security Group Aurora
########################
resource "aws_security_group" "aurora_sg" {
  name        = "${local.name_prefix}-aurora-sg"
  description = "Aurora MySQL access"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-aurora-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "mysql" {
  security_group_id = aws_security_group.aurora_sg.id
  description       = "MySQL access from DEV CIDR"
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  cidr_ipv4         = var.allowed_mysql_cidr
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.aurora_sg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

########################
# DB Subnet Group
########################
resource "aws_db_subnet_group" "aurora_subnets" {
  name       = "${local.name_prefix}-aurora-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-aurora-subnet-group"
  })
}

########################
# Aurora Serverless v2
########################
resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${local.name_prefix}-aurora"
  engine             = "aurora-mysql"
#  engine_version     = "8.0.mysql_aurora.3.05.2"

  database_name   = var.db_name
  master_username = var.db_master_username

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.aurora_subnets.name
  vpc_security_group_ids = [aws_security_group.aurora_sg.id]

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 4
  }

  storage_encrypted   = true
  skip_final_snapshot = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-aurora-cluster"
  })
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name_prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-aurora-writer"
  })
}

########################
# Outputs
########################
output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnets" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_subnets" {
  value = [for s in aws_subnet.private : s.id]
}

output "aurora_sg_id" {
  value = aws_security_group.aurora_sg.id
}

output "db_cluster_endpoint" {
  value = aws_rds_cluster.aurora.endpoint
}

output "db_reader_endpoint" {
  value = aws_rds_cluster.aurora.reader_endpoint
}

output "db_master_user_secret_arn" {
  value     = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
  sensitive = true
}