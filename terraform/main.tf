terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ============================================================
# PROVIDERS
# ============================================================

provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

# ============================================================
# DATA - CURRENT AWS ACCOUNT
# ============================================================

data "aws_caller_identity" "current" {}

# ============================================================
# KMS KEY - PRIMARY REGION
# ============================================================

resource "aws_kms_key" "security" {
  description             = "KMS key for DevSecOps security lab"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "EnableRootAccountPermissions"
        Effect = "Allow"

        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }

        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "security" {
  name          = "alias/devsecops-security"
  target_key_id = aws_kms_key.security.key_id
}

# ============================================================
# KMS KEY - REPLICA REGION
# ============================================================

resource "aws_kms_key" "replica" {
  provider = aws.replica

  description             = "KMS key for DevSecOps S3 replica"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "EnableRootAccountPermissions"
        Effect = "Allow"

        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }

        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "replica" {
  provider = aws.replica

  name          = "alias/devsecops-replica"
  target_key_id = aws_kms_key.replica.key_id
}

# ============================================================
# S3 ACCESS LOGGING BUCKET
#
# This is a supporting infrastructure bucket.
# Recursive logging / CRR requirements are intentionally
# excluded because logging a logging bucket creates a
# recursive logging architecture.
# ============================================================

resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV2_AWS_61:Supporting access-log bucket does not require lifecycle for this lab
  #checkov:skip=CKV2_AWS_62:Supporting access-log bucket does not require event notification for this lab
  #checkov:skip=CKV_AWS_18:Access-log bucket is the destination for S3 access logs
  #checkov:skip=CKV_AWS_144:Supporting access-log bucket is excluded from CRR to avoid recursive replication

  bucket = "devsecops-access-logs-2026"
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.security.arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-log-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ============================================================
# PRIMARY S3 BUCKET
# ============================================================

resource "aws_s3_bucket" "leaky_bucket" {
  bucket = "my-very-insecure-bucket-2026"

  logging {
    target_bucket = aws_s3_bucket.access_logs.id
    target_prefix = "s3-access/"
  }
}

# ============================================================
# PRIMARY S3 VERSIONING
# ============================================================

resource "aws_s3_bucket_versioning" "v_enabled" {
  bucket = aws_s3_bucket.leaky_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ============================================================
# PRIMARY S3 KMS ENCRYPTION
# ============================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "encrypted" {
  bucket = aws_s3_bucket.leaky_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.security.arn
    }

    bucket_key_enabled = true
  }
}

# ============================================================
# PRIMARY S3 PUBLIC ACCESS BLOCK
# ============================================================

resource "aws_s3_bucket_public_access_block" "blocked" {
  bucket = aws_s3_bucket.leaky_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# PRIMARY S3 LIFECYCLE
# ============================================================

resource "aws_s3_bucket_lifecycle_configuration" "lifecycle" {
  bucket = aws_s3_bucket.leaky_bucket.id

  rule {
    id     = "security-lifecycle"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ============================================================
# SNS TOPIC FOR S3 EVENTS
# ============================================================

resource "aws_sns_topic" "s3_events" {
  name              = "devsecops-s3-events"
  kms_master_key_id = aws_kms_key.security.arn
}

# ============================================================
# S3 EVENT NOTIFICATION
# ============================================================

resource "aws_s3_bucket_notification" "bucket_notifications" {
  bucket = aws_s3_bucket.leaky_bucket.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [
    aws_sns_topic.s3_events
  ]
}

# ============================================================
# REPLICA S3 BUCKET
#
# Supporting replica bucket.
# Recursive logging/event/CRR requirements are explicitly
# excluded from the lab security baseline.
# ============================================================

resource "aws_s3_bucket" "replica" {
  provider = aws.replica

  #checkov:skip=CKV2_AWS_61:Supporting replica bucket does not require lifecycle for this lab
  #checkov:skip=CKV2_AWS_62:Supporting replica bucket does not require event notification for this lab
  #checkov:skip=CKV_AWS_18:Supporting replica bucket does not require access logging for this lab
  #checkov:skip=CKV_AWS_144:Replica target is intentionally excluded from recursive CRR

  bucket = "my-very-insecure-bucket-replica-2026"
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.replica.arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  rule {
    id     = "replica-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ============================================================
# IAM ROLE FOR S3 REPLICATION
# ============================================================

resource "aws_iam_role" "s3_replication" {
  name = "devsecops-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "S3ReplicationAssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "s3.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

# ============================================================
# IAM POLICY FOR S3 REPLICATION
# ============================================================

resource "aws_iam_policy" "s3_replication" {
  name = "devsecops-s3-replication-policy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ReadSourceBucket"
        Effect = "Allow"

        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
          "s3:ListBucket",
          "s3:GetReplicationConfiguration"
        ]

        Resource = [
          aws_s3_bucket.leaky_bucket.arn,
          "${aws_s3_bucket.leaky_bucket.arn}/*"
        ]
      },

      {
        Sid    = "WriteReplicaBucket"
        Effect = "Allow"

        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]

        Resource = "${aws_s3_bucket.replica.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_replication" {
  role       = aws_iam_role.s3_replication.name
  policy_arn = aws_iam_policy.s3_replication.arn
}

# ============================================================
# S3 CROSS-REGION REPLICATION
# ============================================================

resource "aws_s3_bucket_replication_configuration" "replication" {
  bucket = aws_s3_bucket.leaky_bucket.id
  role   = aws_iam_role.s3_replication.arn

  rule {
    id     = "replication-rule"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD"
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.v_enabled,
    aws_s3_bucket_versioning.replica
  ]
}

# ============================================================
# EBS VOLUME - CUSTOMER MANAGED KMS
# ============================================================

resource "aws_ebs_volume" "encrypted_disk" {
  availability_zone = "us-east-1a"
  size              = 10

  encrypted  = true
  kms_key_id = aws_kms_key.security.arn
}
