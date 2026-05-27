# IPs públicas de las EC2
output "frontend_public_ip" {
  description = "IP elástica del frontend"
  value       = aws_eip.frontend.public_ip
}

# Endpoint de la base de datos
output "rds_endpoint" {
  description = "Endpoint de la RDS"
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "Address de la RDS (sin puerto)"
  value       = aws_db_instance.main.address
}

# Bucket S3
output "bucket_name" {
  description = "Nombre del bucket S3"
  value       = aws_s3_bucket.main.bucket
}

# Comandos SSH listos para copiar y pegar
output "ssh_frontend" {
  description = "Comando SSH al frontend"
  value       = "ssh -i keys/frontend-key.pem ec2-user@${aws_eip.frontend.public_ip}"
}

# URLs de los repositorios ECR
output "ecr_backend_url" {
  value       = aws_ecr_repository.backend.repository_url
  description = "URL del repo ECR del backend"
}

output "ecr_pipelines_url" {
  value       = aws_ecr_repository.pipelines.repository_url
  description = "URL del repo ECR de pipelines"
}

output "ecr_frontend_url" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "URL del repo ECR del frontend"
}