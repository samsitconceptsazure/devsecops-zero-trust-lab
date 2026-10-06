provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "leaky_bucket" {
  bucket = "my-very-insecure-bucket-2026"
}

resource "aws_s3_bucket_versioning" "v_enabled" {
  bucket = aws_s3_bucket.leaky_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "encrypted" {
  bucket = aws_s3_bucket.leaky_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "blocked" {
  bucket = aws_s3_bucket.leaky_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ebs_volume" "encrypted_disk" {
  availability_zone = "us-east-1a"
  size              = 10
  encrypted         = true
}
