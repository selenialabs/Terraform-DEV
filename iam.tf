# Rol IAM para que las EC2 puedan acceder a S3
resource "aws_iam_role" "ec2_s3_role" {
  name = "${var.project_name}-${var.environment}-ec2-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-s3-role"
  }
}

# Política con permisos sobre el bucket S3
resource "aws_iam_role_policy" "ec2_s3_policy" {
  name = "${var.project_name}-${var.environment}-ec2-policy"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging"
        ]
        Resource = [
          aws_s3_bucket.main.arn,
          "${aws_s3_bucket.main.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance profile (necesario para asociar el rol a las EC2)
resource "aws_iam_instance_profile" "ec2_s3_profile" {
  name = "${var.project_name}-${var.environment}-ec2-s3-profile"
  role = aws_iam_role.ec2_s3_role.name

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-s3-profile"
  }
}