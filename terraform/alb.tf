resource "aws_lb" "main" {
  name               = "ms-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

# Blue + green target group pour chaque service (target_type=ip obligatoire en Fargate/awsvpc)
resource "aws_lb_target_group" "blue" {
  for_each    = local.services
  name        = "${each.key}-blue"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  deregistration_delay = 30
  health_check {
    path    = "/health"
    matcher = "200"
  }
}
resource "aws_lb_target_group" "green" {
  for_each    = local.services
  name        = "${each.key}-green"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  deregistration_delay = 30
  health_check {
    path    = "/health"
    matcher = "200"
  }
}

# Listener de production. Défaut = orders (CodeDeploy bascule CE listener entre blue/green).
resource "aws_lb_listener" "prod" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue["orders"].arn
  }
  lifecycle { ignore_changes = [default_action] } # CodeDeploy modifie l'action
}

# Listener de test : on valide la version "green" ici avant de basculer la prod
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green["orders"].arn
  }
  lifecycle { ignore_changes = [default_action] }
}

# Routage par chemin pour auth et notifications (déploiement rolling + circuit breaker)
resource "aws_lb_listener_rule" "path" {
  for_each     = { for k, v in local.services : k => v if k != "orders" }
  listener_arn = aws_lb_listener.prod.arn
  priority     = each.value.priority
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue[each.key].arn
  }
  condition {
    path_pattern { values = [each.value.path] }
  }
}
