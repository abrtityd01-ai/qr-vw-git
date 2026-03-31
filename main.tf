########################
# 1. VPC + Subnets
########################
resource "aws_vpc" "qr_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "isolated_a" {
  vpc_id            = aws_vpc.qr_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "isolated_b" {
  vpc_id            = aws_vpc.qr_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
}

########################
# 2. VPC Endpoints
########################
resource "aws_security_group" "vpce_sg" {
  vpc_id = aws_vpc.qr_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id            = aws_vpc.qr_vpc.id
  service_name      = "com.amazonaws.us-east-1.secretsmanager"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [aws_subnet.isolated_a.id, aws_subnet.isolated_b.id]
  security_group_ids = [aws_security_group.vpce_sg.id]
}

resource "aws_vpc_endpoint" "rds_data" {
  vpc_id            = aws_vpc.qr_vpc.id
  service_name      = "com.amazonaws.us-east-1.rds-data"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [aws_subnet.isolated_a.id, aws_subnet.isolated_b.id]
  security_group_ids = [aws_security_group.vpce_sg.id]
}

########################
# 3. Aurora Serverless v2
########################
resource "aws_rds_cluster" "qr_cluster" {
  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.05.2"
  database_name  = "qrdb"

  master_username = "admin"
  manage_master_user_password = true

  db_subnet_group_name = aws_db_subnet_group.qr_subnet_group.name

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 1.0
  }

  storage_encrypted = true
  enable_http_endpoint = true # Data API

  skip_final_snapshot = true
}

resource "aws_db_subnet_group" "qr_subnet_group" {
  name       = "qr-subnet-group"
  subnet_ids = [
    aws_subnet.isolated_a.id,
    aws_subnet.isolated_b.id
  ]
}

resource "aws_rds_cluster_instance" "writer" {
  cluster_identifier = aws_rds_cluster.qr_cluster.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.qr_cluster.engine
}

########################
# 4. IAM para Lambda
########################
resource "aws_iam_role" "lambda_role" {
  name = "qr_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "rds_data_api_policy" {
  name = "rds-data-api-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds-data:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.rds_data_api_policy.arn
}

########################
# 5. Lambda
########################
resource "aws_lambda_function" "qr_processor" {
  function_name = "qr-processor"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"

  filename         = "lambda.zip" # Debes empaquetar el código
  source_code_hash = filebase64sha256("lambda.zip")

  environment {
    variables = {
      DB_CLUSTER_ARN = aws_rds_cluster.qr_cluster.arn
      SECRET_ARN     = aws_rds_cluster.qr_cluster.master_user_secret[0].secret_arn
    }
  }

  tracing_config {
    mode = "Active"
  }
}

########################
# 6. Outputs
########################
output "cluster_arn" {
  value = aws_rds_cluster.qr_cluster.arn
}

output "secret_arn" {
  value = aws_rds_cluster.qr_cluster.master_user_secret[0].secret_arn
}