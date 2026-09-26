#!/usr/bin/env bash
set -e

# 1. Load AWS credentials
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
set -a
source .env
set +a
export AWS_REGION=ap-south-1

# 2. Check desired, running, and pending task counts
aws ecs describe-services \
  --cluster flask-fargate-cluster \
  --services flask-service

# 3. Find one running task
TASK_ARN="$(aws ecs list-tasks \
  --cluster flask-fargate-cluster \
  --service-name flask-service \
  --query 'taskArns[0]' \
  --output text)"

# 4. Inspect that task
aws ecs describe-tasks \
  --cluster flask-fargate-cluster \
  --tasks "$TASK_ARN"

# 5. Find the task's network interface
ENI_ID="$(aws ecs describe-tasks \
  --cluster flask-fargate-cluster \
  --tasks "$TASK_ARN" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" \
  --output text)"

# 6. Find its public IP
PUBLIC_IP="$(aws ec2 describe-network-interfaces \
  --network-interface-ids "$ENI_ID" \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text)"
echo "Public URL: http://$PUBLIC_IP:5000"

# 7. Test the deployed API
curl --max-time 10 "http://$PUBLIC_IP:5000/api/data"

# 8. Show recent application logs
aws logs tail /ecs/flask-app-task --since 10m
