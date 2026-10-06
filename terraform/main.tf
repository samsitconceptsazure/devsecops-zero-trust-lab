provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "leaky_bucket" {
  bucket = "my-very-insecure-bucket-2026"
  # Missing: versioning, encryption, and public access blocks!
}

resource "aws_ebs_volume" "unencrypted_disk" {
  availability_zone = "us-east-1a"
  size              = 10
  # Missing: encrypted = true
}
