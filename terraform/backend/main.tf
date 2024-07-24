
provider "aws" {
  region = var.aws_region
}

# Create an S3 bucket for storing Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "tf-state-bucket-mperetz2"
  acl    = "private"
}

# Create a DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}