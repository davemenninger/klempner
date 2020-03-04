# ROLES
# one for pipeline
# one for build

resource "aws_iam_role" "codepipeline_role" {
  name = "${var.appname}-codebuild-service"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role" "codebuild_role" {
  name = "${var.appname}-codebuild-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# POLICIES
# one for pipeline
# one for build

resource "aws_iam_role_policy" "codebuild_role_policy" {
  name = "${var.appname}-codebuild_role_policy"
  role = "${aws_iam_role.codebuild_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning"
      ],
      "Resource": "*",
      "Effect": "Allow",
      "Sid": "AccessCodePipelineArtifacts"
    },
    {
         "Sid":"logStream",
         "Effect":"Allow",
         "Action":[
            "logs:PutLogEvents",
            "logs:CreateLogGroup",
            "logs:CreateLogStream"
         ],
         "Resource":"arn:aws:logs:${var.region}:*:*"
    },
    {
         "Effect":"Allow",
         "Action":[
            "ecr:GetAuthorizationToken"
         ],
         "Resource":"*"
    },
    {
         "Effect":"Allow",
         "Action":[
            "ecr:GetAuthorizationToken",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:BatchCheckLayerAvailability",
            "ecr:PutImage",
            "ecr:InitiateLayerUpload",
            "ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload"
         ],
         "Resource":"${aws_ecr_repository.ecr_repository.arn}"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_role_policy" {
  name = "${var.appname}-codepipeline_policy"
  role = "${aws_iam_role.codepipeline_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

# BUCKET
# for source

resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = "${var.appname}-source"
  acl    = "private"
}

# PIPELINE
# stages:
# - get source
# - run tests
# - build and push image
# - TODO: update running cluster

resource "aws_codepipeline" "codepipeline" {
  name     = "${var.appname}-pipeline"
  role_arn = "${aws_iam_role.codepipeline_role.arn}"

  artifact_store {
    location = "${aws_s3_bucket.codepipeline_bucket.bucket}"
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "App"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["Source"]

      configuration = {
        Owner      = "davemenninger"
        Repo       = "${var.githubRepository}"
        Branch     = "master"
        OAuthToken = "${var.github_oauth_token}"
      }
    }
  }

  stage {
    name = "Test"

    action {
      name             = "Test"
      category         = "Test"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["Source"]
      output_artifacts = ["TestOutput"]
      version          = "1"

      configuration = {
        ProjectName = "${var.appname}-codebuild-test"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["TestOutput", "Source"]
      output_artifacts = ["BuildOutput"]
      version          = "1"

      configuration = {
        ProjectName   = "${var.appname}-codebuild-build"
        PrimarySource = "Source"
      }
    }
  }
}

# CODEBUILD
# one for running tests
# one for build and push image

resource "aws_codebuild_project" "codebuild_test_project" {
  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    type            = "LINUX_CONTAINER"
    image           = "aws/codebuild/docker:17.09.0"
    privileged_mode = true
  }

  name         = "${var.appname}-codebuild-test"
  service_role = "${aws_iam_role.codebuild_role.id}"

  source {
    type = "CODEPIPELINE"

    buildspec = <<EOF
version: 0.2
phases:
  pre_build:
    commands:
      - make greet
  build:
    commands:
      - make test
  post_build:
    commands:
      - echo "{}" > build.json
artifacts:
  files: build.json
EOF
  }
}

resource "aws_codebuild_project" "codebuild_build_project" {
  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    type            = "LINUX_CONTAINER"
    image           = "aws/codebuild/docker:17.09.0"
    privileged_mode = true

    environment_variable {
      name  = "REPOSITORY_URI"
      value = "${aws_ecr_repository.ecr_repository.repository_url}"
    }
  }

  name         = "${var.appname}-codebuild-build"
  service_role = "${aws_iam_role.codebuild_role.id}"

  source {
    type = "CODEPIPELINE"

    buildspec = <<EOF
version: 0.2
phases:
  pre_build:
    commands:
      - $(aws ecr get-login --no-include-email)
      - TAG="$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | head -c 8)"
      - IMAGE_URI="$${REPOSITORY_URI}:$${TAG}"
  build:
    commands:
      - docker build --tag "$${IMAGE_URI}" . --target runtime
  post_build:
    commands:
      - docker push "$IMAGE_URI"
      - printf '{"ImageUri":"%s"}' "$IMAGE_URI" > build.json
artifacts:
  files: build.json
EOF
  }
}

# ECR REPOSITORY
# to store our built images

resource "aws_ecr_repository" "ecr_repository" {
  name = "${var.appname}"
}

# ECS Cluster
# run our app

resource "aws_ecs_cluster" "foo" {
  name = "${var.appname}-cluster"
}

resource "aws_ecs_service" "web" {
  name            = "web"
  cluster         = "${aws_ecs_cluster.foo.id}"
  # task_definition = "${aws_ecs_task_definition.web.arn}"
  task_definition = "${aws_ecs_task_definition.web.family}:${max("${aws_ecs_task_definition.web.revision}", "${data.aws_ecs_task_definition.web.revision}")}"


  desired_count   = 2
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = "${aws_lb_target_group.foo.arn}"
    container_name   = "foo"
    container_port   = 4000
  }

  network_configuration {
    subnets = "${var.subnets}"
    security_groups = ["${aws_security_group.lb_sg.id}"]
  }
}

data "aws_ecs_task_definition" "web" {
  task_definition = "${aws_ecs_task_definition.web.family}"
}

resource "aws_ecs_task_definition" "web" {
  cpu = 512
  memory = 1024
  family                = "web"
  container_definitions = "${file("task-definitions/cd.json")}"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn = "${aws_iam_role.fargate_role.arn}"
}

resource "aws_lb_target_group" "foo" {
  name     = "tf-example-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${var.vpc_id}"
  target_type = "ip"
}

resource "aws_lb" "test" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.lb_sg.id}"]
  subnets            = "${var.subnets}"

  enable_deletion_protection = true
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

resource "aws_lb_listener" "foo" {
  load_balancer_arn = "${aws_lb.test.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.foo.arn}"
  }
}

resource "aws_cloudwatch_log_group" "foo" {
  name = "/ecs/foo"
}

resource "random_password" "rds_password" {
  length = 16
  special = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

resource "aws_ssm_parameter" "rds_password" {
  name  = "foo_password"
  type  = "String"
  value = "${random_password.rds_password.result}"
}

resource "aws_db_instance" "foo_db" {
  allocated_storage    = 20
  engine               = "postgres"
  instance_class       = "db.t2.micro"
  name                 = "foo_db"
  username             = "postgres"
  password             = "${random_password.rds_password.result}"
}

resource "aws_ssm_parameter" "rds_ecto_url" {
  name  = "foo_database_url"
  type  = "String"
  value = "ecto://postgres:${random_password.rds_password.result}@${aws_db_instance.foo_db.endpoint}/${var.appname}"
}
