# S3 bucket for Vault Raft snapshot backups.
#
# object_lock_enabled MUST be set at creation time — AWS does not allow
# enabling it retroactively on an existing bucket. Existing buckets that
# need protection must be recreated (or migrated via S3 Replication).
resource "aws_s3_bucket" "backup" {
  bucket              = var.bucket_name
  object_lock_enabled = var.object_lock_enabled

  tags = merge(var.tags, {
    Name = var.bucket_name
  })
}

# Deny any request that isn't using TLS — blocks credential sniffing over
# in-VPC or on-prem proxy paths that might strip TLS.
data "aws_iam_policy_document" "backup_bucket_policy" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.backup_bucket_policy.json
}

# Default Object Lock retention rule — applied to every uploaded object.
# GOVERNANCE mode (not COMPLIANCE): privileged operators with the
# s3:BypassGovernanceRetention permission can still delete if genuinely
# necessary (e.g., legal hold removal, mistaken upload). COMPLIANCE mode
# would be undeletable by anyone including root — generally too strict.
resource "aws_s3_bucket_object_lock_configuration" "backup" {
  count  = var.object_lock_enabled ? 1 : 0
  bucket = aws_s3_bucket.backup.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.backup]
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  # Daily snapshots: transition to IA at 30 days, expire at retention limit
  rule {
    id     = "daily-snapshots"
    status = "Enabled"

    filter {
      prefix = "${var.cluster_name}/daily/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.daily_retention_days
    }
  }

  # Weekly snapshots: transition to Glacier at 60 days, expire at 365 days
  rule {
    id     = "weekly-snapshots"
    status = "Enabled"

    filter {
      prefix = "${var.cluster_name}/weekly/"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    expiration {
      days = var.weekly_retention_days
    }
  }

  # Sync snapshots: expire at 30 days
  rule {
    id     = "sync-snapshots"
    status = "Enabled"

    filter {
      prefix = "${var.cluster_name}/sync/"
    }

    expiration {
      days = 30
    }
  }
}

# IAM policy granting Vault nodes access to the backup bucket
resource "aws_iam_role_policy" "vault_s3_backup" {
  name = "${var.cluster_name}-s3-backup"
  role = var.vault_iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.backup.arn,
          "${aws_s3_bucket.backup.arn}/*"
        ]
      }
    ]
  })
}
