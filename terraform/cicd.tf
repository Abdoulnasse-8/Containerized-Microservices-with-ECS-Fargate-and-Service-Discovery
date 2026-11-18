# --- CodeDeploy blue/green pour orders ---
resource "aws_iam_role" "codedeploy" {
  name = "ms-codedeploy"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "codedeploy.amazonaws.com" } }] })
}
resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "orders" {
  name             = "orders"
  compute_platform = "ECS"
}
resource "aws_codedeploy_deployment_group" "orders" {
  app_name               = aws_codedeploy_app.orders.name
  deployment_group_name  = "orders-bg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes" # 10% puis 100% après 5 min

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
  blue_green_deployment_config {
    deployment_ready_option { action_on_timeout = "CONTINUE_DEPLOYMENT" }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.svc["orders"].name
  }
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route { listener_arns = [aws_lb_listener.prod.arn] }
      test_traffic_route { listener_arns = [aws_lb_listener.test.arn] }
      target_group { name = aws_lb_target_group.blue["orders"].name }
      target_group { name = aws_lb_target_group.green["orders"].name }
    }
  }
}

# --- CodeBuild : build Docker + push ECR + génère imageDetail.json ---
resource "aws_s3_bucket" "artifacts" {
  bucket        = "ms-pipeline-${data.aws_caller_identity.me.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_iam_role" "codebuild" {
  name = "ms-codebuild"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "codebuild.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "codebuild" {
  role = aws_iam_role.codebuild.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = aws_ecr_repository.svc["orders"].arn },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion"], Resource = "${aws_s3_bucket.artifacts.arn}/*" }
  ] })
}

resource "aws_codebuild_project" "orders" {
  name         = "orders-build"
  service_role = aws_iam_role.codebuild.arn
  artifacts { type = "CODEPIPELINE" }
  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec.yml"
  }
  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # nécessaire pour docker build
    environment_variable {
      name  = "ECR_REPO"
      value = aws_ecr_repository.svc["orders"].repository_url
    }
  }
}

# --- CodePipeline : Source (GitHub via CodeStar) -> Build -> Deploy (CodeDeploy ECS) ---
variable "github_repo" {
  type        = string
  description = "ex: moncompte/aws-ecs-microservices"
  default     = ""
}
variable "create_pipeline" {
  type    = bool
  default = false # active après avoir poussé le repo sur GitHub
}

resource "aws_codestarconnections_connection" "gh" {
  count         = var.create_pipeline ? 1 : 0
  name          = "github-ms"
  provider_type = "GitHub" # à AUTORISER manuellement dans la console (Developer Tools > Connections)
}

resource "aws_iam_role" "pipeline" {
  count = var.create_pipeline ? 1 : 0
  name  = "ms-pipeline"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "codepipeline.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "pipeline" {
  count = var.create_pipeline ? 1 : 0
  role  = aws_iam_role.pipeline[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:*"], Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
    { Effect = "Allow", Action = ["codestar-connections:UseConnection"], Resource = aws_codestarconnections_connection.gh[0].arn },
    { Effect = "Allow", Action = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"], Resource = aws_codebuild_project.orders.arn },
    { Effect = "Allow", Action = ["codedeploy:CreateDeployment", "codedeploy:GetDeployment", "codedeploy:GetDeploymentConfig", "codedeploy:GetApplicationRevision", "codedeploy:RegisterApplicationRevision"], Resource = "*" },
    { Effect = "Allow", Action = ["ecs:RegisterTaskDefinition", "ecs:DescribeServices", "ecs:UpdateService", "ecs:DescribeTaskDefinition"], Resource = "*" },
    { Effect = "Allow", Action = ["iam:PassRole"], Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn] }
  ] })
}

resource "aws_codepipeline" "orders" {
  count    = var.create_pipeline ? 1 : 0
  name     = "orders-pipeline"
  role_arn = aws_iam_role.pipeline[0].arn
  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }
  stage {
    name = "Source"
    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["src"]
      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.gh[0].arn
        FullRepositoryId = var.github_repo
        BranchName       = "main"
      }
    }
  }
  stage {
    name = "Build"
    action {
      name             = "DockerBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["src"]
      output_artifacts = ["build"]
      configuration    = { ProjectName = aws_codebuild_project.orders.name }
    }
  }
  stage {
    name = "Deploy"
    action {
      name            = "BlueGreen"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build"]
      configuration = {
        ApplicationName                = aws_codedeploy_app.orders.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.orders.deployment_group_name
        TaskDefinitionTemplateArtifact = "build"
        TaskDefinitionTemplatePath     = "taskdef.json"
        AppSpecTemplateArtifact        = "build"
        AppSpecTemplatePath            = "appspec.yaml"
        Image1ArtifactName             = "build"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }
}
