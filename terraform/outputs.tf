output "alb_url" { value = "http://${aws_lb.main.dns_name}" }
output "test_url" { value = "http://${aws_lb.main.dns_name}:8080" }
output "ecr_repos" { value = { for k, r in aws_ecr_repository.svc : k => r.repository_url } }
output "demo_password_hint" { value = "aws secretsmanager get-secret-value --secret-id ms/app-secrets" }
