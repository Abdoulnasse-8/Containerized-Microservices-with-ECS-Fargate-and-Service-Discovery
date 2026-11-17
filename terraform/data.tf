# --- ECR : un repo par service, scan de vulnérabilités à chaque push ---
resource "aws_ecr_repository" "svc" {
  for_each             = local.services
  name                 = "ms/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # pratique pour le lab (terraform destroy)
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({ rules = [{
    rulePriority = 1, description = "garder 10 images",
    selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 },
    action       = { type = "expire" }
  }] })
}

# --- Secrets Manager : injectés dans les conteneurs au démarrage ---
resource "random_password" "demo" {
  length  = 20
  special = false
}
resource "random_password" "api_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "ms/app-secrets"
  recovery_window_in_days = 0 # suppression immédiate (lab)
}
resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    DEMO_PASSWORD = random_password.demo.result
    API_KEY       = random_password.api_key.result
  })
}

# --- ElastiCache Redis : sessions partagées ---
resource "aws_elasticache_subnet_group" "redis" {
  name       = "ms-redis"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "ms-sessions"
  description                = "Sessions partagees"
  engine                     = "redis"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1 # lab : 1 nœud (prod : 2 pour le multi-AZ)
  automatic_failover_enabled = false # requiert >= 2 nœuds
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # simplifie le client Redis du lab ; activer + TLS en prod
}

# --- Cloud Map : auth.ecs.local, orders.ecs.local, ... ---
resource "aws_service_discovery_private_dns_namespace" "ns" {
  name = "ecs.local"
  vpc  = aws_vpc.main.id
}
resource "aws_service_discovery_service" "svc" {
  for_each = local.services
  name     = each.key
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.ns.id
    dns_records {
      type = "A"
      ttl  = 10
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config { failure_threshold = 1 }
}
