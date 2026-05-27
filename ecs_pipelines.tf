# ============================================================================
# Pipelines en Fargate event-driven
# ----------------------------------------------------------------------------
# Reemplaza la EC2 t3.small de Dagster (ec2.tf:aws_instance.pipelines) por
# tasks Fargate one-shot disparadas por eventos S3:ObjectCreated. Cada upload
# en s3://bucket/<ventas|productos|ventas_por_productos>/*.xlsx levanta una
# task que corre `python entrypoint.py` con S3_KEY como override, procesa el
# archivo (pandas + RDS) y muere.
#
# Este archivo coexiste con la EC2 vieja hasta que validemos en Fase 3 y
# hagamos cutover en Fase 4. No se borra nada de ec2.tf / security_groups.tf
# todavía.
# ============================================================================

# ----------------------------------------------------------------------------
# 1. ECS cluster (es solo un nombre lógico, no cuesta nada)
# ----------------------------------------------------------------------------
resource "aws_ecs_cluster" "pipelines" {
  name = "${var.project_name}-${var.environment}-pipelines"

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-cluster"
  }
}

# ----------------------------------------------------------------------------
# 2. CloudWatch log group para los logs de las tasks
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "pipelines" {
  name              = "/ecs/${var.project_name}-${var.environment}-pipelines"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-logs"
  }
}

# ----------------------------------------------------------------------------
# 3. Security group para las tasks Fargate
#    Egress only: las tasks no reciben tráfico entrante, solo salen a S3/ECR/RDS.
# ----------------------------------------------------------------------------
resource "aws_security_group" "pipelines_tasks" {
  name        = "${var.project_name}-${var.environment}-pipelines-tasks-sg"
  description = "SG para tasks Fargate de pipelines (egress only)"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS a S3 / ECR / CloudWatch Logs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PostgreSQL a RDS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-tasks-sg"
  }
}

# Nota: el ingress de 5432 desde aws_security_group.pipelines_tasks al SG de
# RDS se define como bloque inline en security_groups.tf:aws_security_group.rds,
# no acá. Mezclar bloques inline con aws_vpc_security_group_ingress_rule en
# un mismo SG produce drift perpetuo (el provider los considera mutuamente
# excluyentes).

# ----------------------------------------------------------------------------
# 4. IAM task execution role
#    Lo usa ECS Fargate para PULL de ECR y push de logs a CloudWatch.
#    NO es el rol del código que corre dentro del contenedor.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "pipelines_task_execution" {
  name = "${var.project_name}-${var.environment}-pipelines-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-task-execution"
  }
}

resource "aws_iam_role_policy_attachment" "pipelines_task_execution_managed" {
  role       = aws_iam_role.pipelines_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ----------------------------------------------------------------------------
# 5. IAM task role
#    Lo asume el código dentro del contenedor — boto3 lo levanta automáticamente.
#    Permisos: leer/escribir objetos del bucket + leer tagging.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "pipelines_task" {
  name = "${var.project_name}-${var.environment}-pipelines-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-task"
  }
}

resource "aws_iam_role_policy" "pipelines_task_s3" {
  name = "${var.project_name}-${var.environment}-pipelines-task-s3"
  role = aws_iam_role.pipelines_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
        ]
        Resource = "${aws_s3_bucket.main.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.main.arn
      },
    ]
  })
}

# ----------------------------------------------------------------------------
# 6. ECS task definition (Fargate)
#    0.25 vCPU + 512 MB para empezar — perfil "burst" suficiente para los ETLs
#    actuales (2-5 min, pandas con archivos chicos). Si vemos OOM o lentitud,
#    se sube. Cuesta ~$0.012/hora prendida.
# ----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "pipelines" {
  family                   = "${var.project_name}-${var.environment}-pipelines"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.pipelines_task_execution.arn
  task_role_arn      = aws_iam_role.pipelines_task.arn

  container_definitions = jsonencode([{
    name      = "pipeline"
    image     = "${aws_ecr_repository.pipelines.repository_url}:fargate-latest"
    essential = true

    environment = [
      { name = "BUCKET_NAME", value = aws_s3_bucket.main.bucket },
      { name = "AWS_REGION", value = var.region },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_USER", value = var.db_username },
      { name = "DB_PASSWORD", value = var.db_password },
      { name = "DB_NAME", value = "selenia" },
      { name = "DB_PORT", value = "5432" },
      # S3_KEY lo inyecta EventBridge por containerOverrides en cada invocación.
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.pipelines.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-taskdef"
  }
}

# ----------------------------------------------------------------------------
# 7. Activar EventBridge notifications en el bucket S3
#    Necesario para que los eventos lleguen al event bus default y matcheen
#    nuestras rules. Solo puede haber UNA bucket_notification por bucket.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_notification" "main_eventbridge" {
  bucket      = aws_s3_bucket.main.id
  eventbridge = true
}

# ----------------------------------------------------------------------------
# 8. EventBridge rule: una sola para todos los .xlsx del bucket.
#    El entrypoint.py del contenedor dispatchea por prefix internamente y
#    descarta prefixes sin pipeline configurado. Una rule = una task por
#    upload (en versiones anteriores eran 3 rules con array OR-ambiguo que
#    matcheaba 3 veces cada upload).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "pipeline_upload" {
  name        = "${var.project_name}-${var.environment}-pipeline-upload"
  description = "Dispara task Fargate al uploadear cualquier .xlsx en s3://${aws_s3_bucket.main.bucket}"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.main.bucket] }
      object = {
        key = [{ suffix = ".xlsx" }]
      }
    }
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-pipeline-upload-rule"
  }
}

# ----------------------------------------------------------------------------
# 9. IAM role para que EventBridge pueda hacer RunTask en ECS
#    Necesita ecs:RunTask + iam:PassRole sobre execution_role y task_role.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "eventbridge_ecs" {
  name = "${var.project_name}-${var.environment}-eventbridge-ecs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-eventbridge-ecs"
  }
}

resource "aws_iam_role_policy" "eventbridge_ecs" {
  name = "${var.project_name}-${var.environment}-eventbridge-ecs"
  role = aws_iam_role.eventbridge_ecs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "${aws_ecs_task_definition.pipelines.arn_without_revision}:*"
      },
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.pipelines_task_execution.arn,
          aws_iam_role.pipelines_task.arn,
        ]
      },
    ]
  })
}

# ----------------------------------------------------------------------------
# 10. EventBridge targets: cada rule dispara RunTask en Fargate y pasa S3_KEY
#     extraído del evento como containerOverride.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_event_target" "pipeline_runtask" {
  rule     = aws_cloudwatch_event_rule.pipeline_upload.name
  arn      = aws_ecs_cluster.pipelines.arn
  role_arn = aws_iam_role.eventbridge_ecs.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.pipelines.arn
    launch_type         = "FARGATE"
    platform_version    = "LATEST"

    network_configuration {
      subnets          = [aws_subnet.public_1.id, aws_subnet.public_2.id]
      security_groups  = [aws_security_group.pipelines_tasks.id]
      assign_public_ip = true # subnets públicas, sin NAT GW
    }
  }

  input_transformer {
    input_paths = {
      key = "$.detail.object.key"
    }
    input_template = <<EOF
{
  "containerOverrides": [
    {
      "name": "pipeline",
      "environment": [
        { "name": "S3_KEY", "value": <key> }
      ]
    }
  ]
}
EOF
  }
}

# ----------------------------------------------------------------------------
# Outputs útiles para debug / scripts manuales de RunTask
# ----------------------------------------------------------------------------
output "pipelines_ecs_cluster_name" {
  value       = aws_ecs_cluster.pipelines.name
  description = "Nombre del ECS cluster que corre las tasks de pipelines"
}

output "pipelines_task_definition_arn" {
  value       = aws_ecs_task_definition.pipelines.arn
  description = "ARN de la task definition (incluye revisión)"
}

output "pipelines_log_group" {
  value       = aws_cloudwatch_log_group.pipelines.name
  description = "CloudWatch log group para los logs de las tasks"
}
