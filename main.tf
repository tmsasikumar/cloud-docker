# 1. Fetch Default VPC and Subnets
resource "aws_default_vpc" "default" {}

resource "aws_default_subnets" "default" {
  availability_zone = ["ap-south-1a", "ap-south-1b"]
}

# 2. Security Group (Firewall allowing HTTP access on Port 5000)
resource "aws_security_group" "ecs_sg" {
  name        = "flask-ecs-sg"
  description = "Allow inbound web traffic"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Updated ECS Service with Mandatory Network Configuration
resource "aws_ecs_service" "flask_service" {
  name            = "flask-service"
  cluster         = aws_ecs_cluster.main_cluster.id
  task_definition = aws_ecs_task_definition.flask_app.arn
  launch_type     = "FARGATE"
  desired_count   = 2

  network_configuration {
    subnets          = aws_default_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true # Assigns a public IP so students can open it in a browser
  }
}