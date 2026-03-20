# IAM role for Vault EC2 instances
resource "aws_iam_role" "vault" {
  name = "${var.cluster_name}-vault-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vault-role"
  })
}

# Instance profile for EC2
resource "aws_iam_instance_profile" "vault" {
  name = "${var.cluster_name}-vault-profile"
  role = aws_iam_role.vault.name

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vault-profile"
  })
}

# Policy for KMS auto-unseal
resource "aws_iam_role_policy" "vault_kms" {
  name = "${var.cluster_name}-kms-unseal"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# Policy for EC2 auto-join (Raft cluster discovery)
resource "aws_iam_role_policy" "vault_ec2" {
  name = "${var.cluster_name}-ec2-discovery"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# Policy for Secrets Manager (CA cert/key retrieval + vault credential storage)
resource "aws_iam_role_policy" "vault_secrets" {
  name = "${var.cluster_name}-secrets-access"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.secrets_manager_arns
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:PutSecretValue"
        ]
        Resource = var.secrets_manager_arns
      }
    ]
  })
}

# Attach SSM managed policy for Session Manager access (optional but useful)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Policy for SSM Session Manager logging
resource "aws_iam_role_policy" "ssm_logs" {
  name = "${var.cluster_name}-ssm-logs"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = "arn:aws:s3:::${var.ssm_logs_s3_bucket}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetEncryptionConfiguration"
        ]
        Resource = "arn:aws:s3:::${var.ssm_logs_s3_bucket}"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:log-group:${var.ssm_logs_log_group}:*"
      }
    ]
  })
}
