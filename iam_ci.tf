# Usuario IAM para GitHub Actions
resource "aws_iam_user" "github_actions" {
  name = "${var.project_name}-${var.environment}-github-actions"

  tags = {
    Name = "${var.project_name}-${var.environment}-github-actions"
  }
}

# Política con permisos para pushear a los ECRs
resource "aws_iam_user_policy" "github_actions_ecr" {
  name = "${var.project_name}-${var.environment}-github-actions-ecr-policy"
  user = aws_iam_user.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [
          aws_ecr_repository.backend.arn,
          aws_ecr_repository.pipelines.arn,
          aws_ecr_repository.frontend.arn
        ]
      }
    ]
  })
}

# Generar Access Key para el usuario
resource "aws_iam_access_key" "github_actions" {
  user = aws_iam_user.github_actions.name
}

# Output con las credenciales (van a aparecer en el output de Terraform)
output "github_actions_access_key_id" {
  value     = aws_iam_access_key.github_actions.id
  sensitive = true
}

output "github_actions_secret_access_key" {
  value     = aws_iam_access_key.github_actions.secret
  sensitive = true
}