#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Environment file not found: $ENV_FILE" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is required. Install it before running this script." >&2
  exit 1
fi

check_terraform_backend_bucket() {
  local bucket="$1"
  local safe=true
  local value

  echo "Checking Terraform backend bucket: $bucket"

  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "  ERROR: Bucket does not exist or the current credentials cannot access it."
    return 1
  fi

  value="$(aws s3api get-bucket-location \
    --bucket "$bucket" \
    --query "LocationConstraint" \
    --output text)"
  [[ "$value" == "None" ]] && value="us-east-1"
  echo "  Region: $value"

  value="$(aws s3api get-bucket-versioning \
    --bucket "$bucket" \
    --query "Status" \
    --output text)"
  if [[ "$value" == "Enabled" ]]; then
    echo "  Versioning: enabled"
  else
    echo "  ERROR: Versioning is not enabled."
    safe=false
  fi

  if value="$(aws s3api get-bucket-encryption \
    --bucket "$bucket" \
    --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" \
    --output text 2>/dev/null)"; then
    echo "  Default encryption: $value"
  else
    echo "  ERROR: Default bucket encryption could not be verified."
    safe=false
  fi

  if value="$(aws s3api get-public-access-block \
    --bucket "$bucket" \
    --query "PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]" \
    --output text 2>/dev/null)"; then
    if [[ "$(tr -d '[:space:]' <<<"$value")" == "TrueTrueTrueTrue" ]]; then
      echo "  Public access block: fully enabled"
    else
      echo "  ERROR: All four S3 public-access blocks must be enabled."
      safe=false
    fi
  else
    echo "  ERROR: No verifiable S3 public-access block configuration."
    safe=false
  fi

  if value="$(aws s3api get-bucket-policy-status \
    --bucket "$bucket" \
    --query "PolicyStatus.IsPublic" \
    --output text 2>&1)"; then
    if [[ "$value" == "True" ]]; then
      echo "  ERROR: The bucket policy makes this bucket public."
      safe=false
    else
      echo "  Bucket policy: not public"
    fi
  elif [[ "$value" == *"NoSuchBucketPolicy"* ]]; then
    echo "  Bucket policy: none"
  else
    echo "  WARNING: Bucket policy public status could not be verified."
    safe=false
  fi

  value="$(aws s3api get-bucket-acl \
    --bucket "$bucket" \
    --query "length(Grants[?Grantee.URI=='http://acs.amazonaws.com/groups/global/AllUsers' || Grantee.URI=='http://acs.amazonaws.com/groups/global/AuthenticatedUsers'])" \
    --output text)"
  if [[ "$value" == "0" ]]; then
    echo "  Bucket ACL: not public"
  else
    echo "  ERROR: The bucket ACL contains public grants."
    safe=false
  fi

  if ! aws s3api list-objects-v2 \
    --bucket "$bucket" \
    --max-keys 1 >/dev/null 2>&1; then
    echo "  ERROR: Current credentials cannot list the bucket."
    safe=false
  fi

  if [[ "${TERRAFORM_BACKEND_WRITE_TEST:-false}" == "true" ]]; then
    local test_key="cloud-docker/.backend-access-check-${RANDOM}-$$"
    if printf 'Terraform backend access check\n' |
      aws s3 cp - "s3://$bucket/$test_key" --only-show-errors &&
      aws s3 rm "s3://$bucket/$test_key" --only-show-errors; then
      echo "  Backend object write/delete permissions: verified"
    else
      echo "  ERROR: Backend object write/delete test failed."
      safe=false
    fi
  else
    echo "  Write/delete permissions: not tested"
    echo "    Set TERRAFORM_BACKEND_WRITE_TEST=true to run a temporary-object test."
  fi

  if [[ "$safe" == "true" ]]; then
    echo "  Result: bucket configuration is suitable for Terraform state."
    return 0
  fi

  echo "  Result: DO NOT use this bucket for Terraform state until the errors are fixed."
  return 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

aws sts get-caller-identity >/dev/null

TERRAFORM_BACKEND_BUCKET="${TERRAFORM_BACKEND_BUCKET:-test-demo-s3-new}"
if ! check_terraform_backend_bucket "$TERRAFORM_BACKEND_BUCKET"; then
  echo
fi

VPC_ID="$(
  aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text
)"

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "No default VPC found in region $AWS_REGION." >&2
  exit 1
fi

echo "Available subnets in default VPC $VPC_ID ($AWS_REGION):"
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --query "Subnets[].{SubnetId:SubnetId,AvailabilityZone:AvailabilityZone,CIDR:CidrBlock,PublicIPOnLaunch:MapPublicIpOnLaunch}" \
  --output table

echo
echo "Terraform subnet IDs:"
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --query "Subnets[].SubnetId" \
  --output json
