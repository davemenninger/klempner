# ECR REPOSITORY
# to store our built images

resource "aws_ecr_repository" "ecr_repository" {
  name = "${var.appname}"
}

# ECS Cluster
# run our app

resource "aws_ecs_cluster" "ecs_cluster_1" {
  name = "${var.appname}-cluster"
}

resource "aws_ecs_service" "phoenix_service" {
  name            = "phoenix"
  cluster         = "${aws_ecs_cluster.ecs_cluster_1.id}"
  task_definition = "${aws_ecs_task_definition.phoenix_task.family}:${max("${aws_ecs_task_definition.phoenix_task.revision}", "${data.aws_ecs_task_definition.phoenix_task.revision}")}"


  desired_count   = 2
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = "${aws_lb_target_group.phx.arn}"
    container_name   = "phx"
    container_port   = 4000
  }

  network_configuration {
    subnets = "${var.subnets}"
    security_groups = ["${aws_security_group.lb_sg.id}"]
  }
}

data "aws_ecs_task_definition" "phoenix_task" {
  task_definition = "${aws_ecs_task_definition.phoenix_task.family}"
}

resource "aws_ecs_task_definition" "phoenix_task" {
  cpu = 512
  memory = 1024
  family                = "phoenix-server"
  container_definitions = "${file("task-definitions/cd.json")}"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn = "${aws_iam_role.fargate_role.arn}"
}

resource "aws_lb_target_group" "phx" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${var.vpc_id}"
  target_type = "ip"
}

resource "aws_lb" "phx_lb" {
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.lb_sg.id}"]
  subnets            = "${var.subnets}"
}

resource "aws_security_group" "fargate_container_sg" {
  vpc_id      = "${var.vpc_id}"

  ingress {
    from_port       = 80
    to_port         = 5432
    protocol        = "tcp"
    cidr_blocks = [ "10.0.1.0/24" ]

  }
}

resource "aws_security_group" "lb_sg" {
  name        = "allow_tls"
  description = "Allow TLS inbound traffic"
  vpc_id      = "${var.vpc_id}"

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "fargate_role" {
  name = "${var.appname}-fargate"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "fargate_role_policy" {
  name = "${var.appname}-fargate_policy"
  role = "${aws_iam_role.fargate_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeParameters"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameters"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_lb_listener" "public_web" {
  load_balancer_arn = "${aws_lb.phx_lb.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.phx.arn}"
  }
}

resource "aws_cloudwatch_log_group" "phoenix_logs" {
  name = "/ecs/phoenix_logs"
}

resource "random_password" "rds_password" {
  length = 16
  special = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

resource "aws_ssm_parameter" "rds_password" {
  name  = "${var.appname}-rds-password"
  type  = "String"
  value = "${random_password.rds_password.result}"
}

resource "aws_db_instance" "rds_instance" {
  allocated_storage    = 20
  engine               = "postgres"
  instance_class       = "db.t2.micro"
  username             = "postgres"
  password             = "${random_password.rds_password.result}"
}

resource "aws_ssm_parameter" "rds_ecto_url" {
  name  = "${var.appname}-database-url"
  type  = "String"
  value = "ecto://postgres:${random_password.rds_password.result}@${aws_db_instance.rds_instance.endpoint}/${var.appname}"
}
