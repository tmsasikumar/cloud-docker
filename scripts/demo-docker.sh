#!/usr/bin/env bash
set -e

# 1. Load AWS credentials and settings
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
set -a
source .env
set +a
export AWS_REGION=ap-south-1

# 2. First build: Docker creates every image layer
docker build --platform linux/amd64 -t cloud-docker:demo .

# Change app.py or index.html while the script is paused.
read -r -p "Change app.py or index.html, then press Enter to rebuild..."

# 3. Second build: unchanged layers should say "Using cache" or "CACHED"
docker build --platform linux/amd64 -t cloud-docker:demo .

# 4. Run the changed image locally
docker run -d --name cloud-docker-demo -p 5000:5000 cloud-docker:demo

# 5. Test the API
curl --max-time 10 http://localhost:5000/api/data

# 6. Read the ECR repository created by Terraform
ECR_URI="$(terraform output -raw ecr_repository_url)"

# 7. Log in to ECR
aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "${ECR_URI%/*}"

# 8. Tag and push the image
docker tag cloud-docker:demo "$ECR_URI:latest"
docker push "$ECR_URI:latest"

# 9. Stop and remove the local container
docker rm -f cloud-docker-demo
