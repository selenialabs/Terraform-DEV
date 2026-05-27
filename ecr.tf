# Repositorio ECR para el backend
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-${var.environment}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-backend-ecr"
  }
}

# Repositorio ECR para los pipelines
resource "aws_ecr_repository" "pipelines" {
  name                 = "${var.project_name}-${var.environment}-pipelines"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-ecr"
  }
}

# Repositorio ECR para el frontend
resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-${var.environment}-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend-ecr"
  }
}

# Política de lifecycle: borrar imágenes viejas para no acumular costo
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each = {
    backend   = aws_ecr_repository.backend.name
    pipelines = aws_ecr_repository.pipelines.name
    frontend  = aws_ecr_repository.frontend.name
  }

  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las últimas 10 imágenes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}