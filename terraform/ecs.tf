resource "aws_ecs_cluster" "main" {
  name = "ms-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each          = local.services
  name              = "/ecs/${each.key}"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "svc" {
  for_each                 = local.services
  family                   = each.key
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name         = each.key
      image        = "${aws_ecr_repository.svc[each.key].repository_url}:${var.image_tag}"
      essential    = true
      portMappings = [{ containerPort = 3000 }]
      environment = concat(
        [{ name = "AWS_XRAY_DAEMON_ADDRESS", value = "localhost:2000" }],
        each.key == "auth" ? [{ name = "REDIS_HOST", value = aws_elasticache_replication_group.redis.primary_endpoint_address }] : []
      )
      # Injection runtime : ECS lit la clé JSON dans Secrets Manager (format arn:clé::)
      secrets = each.key == "auth" ? [
        { name = "DEMO_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:DEMO_PASSWORD::" }
        ] : each.key == "notifications" ? [
        { name = "API_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:API_KEY::" }
      ] : []
      logConfiguration = { logDriver = "awslogs", options = {
        awslogs-group = aws_cloudwatch_log_group.svc[each.key].name, awslogs-region = var.region, awslogs-stream-prefix = "ecs" } }
    },
    {
      # Sidecar X-Ray : reçoit les traces en UDP 2000 et les envoie à X-Ray
      name         = "xray-daemon"
      image        = "public.ecr.aws/xray/aws-xray-daemon:latest"
      essential    = false
      portMappings = [{ containerPort = 2000, protocol = "udp" }]
    }
  ])
}

resource "aws_ecs_service" "svc" {
  for_each        = local.services
  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # orders = blue/green géré par CodeDeploy ; les autres = rolling update + rollback auto
  deployment_controller { type = each.key == "orders" ? "CODE_DEPLOY" : "ECS" }
  dynamic "deployment_circuit_breaker" {
    for_each = each.key == "orders" ? [] : [1]
    content {
      enable   = true
      rollback = true
    }
  }

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.tasks.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.blue[each.key].arn
    container_name   = each.key
    container_port   = 3000
  }
  service_registries { registry_arn = aws_service_discovery_service.svc[each.key].arn }

  # CodeDeploy / pipeline changent ces valeurs : Terraform ne doit pas les écraser
  lifecycle { ignore_changes = [task_definition, load_balancer, desired_count] }
  depends_on = [aws_lb_listener.prod]
}
