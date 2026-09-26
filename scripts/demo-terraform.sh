#!/usr/bin/env bash
set -e

# 1. Load AWS credentials
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
set -a
source .env
set +a
export AWS_REGION=ap-south-1

# 2. Format the Terraform code
terraform fmt

# 3. Connect to the S3 backend and download providers
terraform init

# 4. Validate the configuration
terraform validate

# 5. Preview the infrastructure changes
terraform plan -var="image_tag=latest" -out=tfplan

# 6. Read the saved plan
terraform show tfplan

# 7. Create or update the AWS resources
terraform apply tfplan

# 8. Show useful results and managed resources
terraform output
terraform state list
