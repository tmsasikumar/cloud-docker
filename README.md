# Flask Docker deployment on AWS ECS

This project packages a Flask application in Docker and deploys it to Amazon
ECS Fargate. Terraform manages the AWS infrastructure, and GitHub Actions
builds and deploys a new image on pushes to `main`.

## Prerequisites

- Docker with a running Docker daemon
- AWS CLI configured with access to the target account
- Terraform 1.10 or newer
- A default VPC in `ap-south-1`
- A private, versioned S3 bucket for Terraform state

Never commit `.env`, AWS access keys, Terraform state, or generated plan files.
The repository ignores these files.

## AWS environment

The local helper scripts load credentials from `.env`:

```dotenv
AWS_ACCESS_KEY_ID=replace-me
AWS_SECRET_ACCESS_KEY=replace-me
AWS_REGION=ap-south-1
```

Load the same variables into the current shell when running commands manually:

```bash
set -a
source .env
set +a
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
```

## Check subnets and the Terraform backend

The helper checks the default VPC subnets and audits `test-demo-s3-new` for
versioning, encryption, public access, and current-account permissions:

```bash
./find-subnets.sh
```

To additionally create and immediately delete a temporary test object:

```bash
TERRAFORM_BACKEND_WRITE_TEST=true ./find-subnets.sh
```

Do not store Terraform state in a public bucket. Enable all public-access
blocks:

```bash
aws s3api put-public-access-block \
  --bucket test-demo-s3-new \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

Inspect the bucket policy:

```bash
aws s3api get-bucket-policy \
  --bucket test-demo-s3-new \
  --query Policy \
  --output text | jq .
```

Remove or rewrite any policy statement that grants public access. If the
bucket policy is unnecessary, it can be removed with:

```bash
aws s3api delete-bucket-policy --bucket test-demo-s3-new
```

Run `./find-subnets.sh` again and continue only when it reports that the bucket
is suitable for Terraform state.

## Build and run Docker locally

Build the image:

```bash
docker build --tag cloud-docker:local .
```

Run it in the background:

```bash
docker run \
  --detach \
  --name cloud-docker-local \
  --publish 5000:5000 \
  cloud-docker:local
```

Test the web page and API:

```bash
curl --fail http://localhost:5000/
curl --fail http://localhost:5000/api/data
```

Inspect the running container:

```bash
docker ps
docker logs --follow cloud-docker-local
```

Stop and remove it:

```bash
docker stop cloud-docker-local
docker rm cloud-docker-local
```

Run it interactively and remove it automatically on exit:

```bash
docker run --rm --interactive --tty --publish 5000:5000 cloud-docker:local
```

Remove the local image when it is no longer needed:

```bash
docker image rm cloud-docker:local
```

## Push an image to Amazon ECR

The ECS task uses Linux x86-64. On Apple Silicon, the `--platform linux/amd64`
option is therefore required for an image built for ECS.

First initialize Terraform and create the ECR repository as described in the
Terraform section. Then set the image details:

```bash
export ECR_REPOSITORY=flask-ecs-demo
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
export IMAGE_TAG="$(git rev-parse --short HEAD)"
```

Authenticate Docker:

```bash
aws ecr get-login-password --region "$AWS_REGION" |
  docker login \
    --username AWS \
    --password-stdin "$ECR_REGISTRY"
```

Build, tag, and push both the immutable revision and `latest`:

```bash
docker build \
  --platform linux/amd64 \
  --tag "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" \
  --tag "$ECR_REGISTRY/$ECR_REPOSITORY:latest" \
  .

docker push "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
docker push "$ECR_REGISTRY/$ECR_REPOSITORY:latest"
```

List pushed images:

```bash
aws ecr describe-images \
  --repository-name "$ECR_REPOSITORY" \
  --region "$AWS_REGION"
```

## Terraform checks without using the remote backend

Formatting does not require AWS access:

```bash
terraform fmt -recursive
terraform fmt -check -recursive
```

Initialize providers in an isolated local data directory and skip the configured
S3 backend:

```bash
TF_DATA_DIR=.terraform-validation terraform init -backend=false
TF_DATA_DIR=.terraform-validation terraform validate
```

This validates configuration only. It does not create resources or produce a
complete AWS plan.

## Terraform plan and deployment

Ensure the backend audit passes, load `.env`, and initialize the S3 backend:

```bash
./find-subnets.sh
terraform init -reconfigure
terraform validate
```

The image cannot be pushed until its ECR repository exists. Bootstrap only that
repository:

```bash
terraform plan -target=aws_ecr_repository.flask -out=ecr.tfplan
terraform apply ecr.tfplan
```

Build and push the image using the ECR commands above. Then create a complete
plan using exactly the tag that was pushed:

```bash
terraform plan \
  -var="image_tag=$IMAGE_TAG" \
  -out=tfplan

terraform show tfplan
terraform apply tfplan
```

Inspect the managed infrastructure:

```bash
terraform output
terraform state list
terraform show
```

Preview drift without changing resources:

```bash
terraform plan -refresh-only
```

After changing Terraform configuration, repeat:

```bash
terraform fmt -recursive
terraform validate
terraform plan -var="image_tag=$IMAGE_TAG" -out=tfplan
terraform apply tfplan
```

## Destroy the AWS resources

Review a destruction plan before applying it:

```bash
terraform plan -destroy -var="image_tag=$IMAGE_TAG" -out=destroy.tfplan
terraform show destroy.tfplan
terraform apply destroy.tfplan
```

The ECR repository is intentionally protected from deletion while it contains
images. Delete its images explicitly only when the repository should also be
destroyed:

```bash
aws ecr list-images \
  --repository-name flask-ecs-demo \
  --query 'imageIds[*]' \
  --output json > /tmp/flask-ecs-image-ids.json

aws ecr batch-delete-image \
  --repository-name flask-ecs-demo \
  --image-ids file:///tmp/flask-ecs-image-ids.json
```

Then rerun the destruction plan.

## GitHub Actions

Add `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as GitHub repository
secrets. On a push to `main`, the workflow:

1. Initializes and validates Terraform.
2. Creates the ECR repository if needed.
3. Builds and pushes the commit-tagged Docker image.
4. Plans and applies the ECS infrastructure and deployment.

Prefer GitHub OpenID Connect and a short-lived AWS role over long-lived access
keys for production repositories.
