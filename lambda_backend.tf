# ============================================================================
# Backend serverless: Lambda + API Gateway HTTP API
# ----------------------------------------------------------------------------
# El compañero migró el backend de EC2 a Lambda + API Gateway en forma manual.
# Este archivo IMPORTA esos recursos a Terraform para que queden versionados.
# Después del primer apply post-import, plan = 0 changes (excepto por
# default_tags que terraform agrega).
#
# La imagen del contenedor está en el repo ECR `selenia-dev-backend` y se
# referencia por digest (sha256) — cuando se pushee una imagen nueva habrá
# que actualizar `var.backend_lambda_image_digest` y re-aplicar.
#
# El VPC endpoint S3 (gateway) también está acá porque se creó manualmente
# durante la sesión cuando el Lambda no podía llegar a S3.
# ============================================================================

variable "backend_lambda_image_digest" {
  description = "Digest sha256 de la imagen Docker del backend en ECR. Update on each image push."
  type        = string
  default     = "sha256:a9b5c93515f5eb1bd65c74c22faaf35e4e57192485b8718d4ff774f689df39fb"
}

# ----------------------------------------------------------------------------
# 1. IAM role para la Lambda (creado por consola con prefix /service-role/)
# ----------------------------------------------------------------------------
resource "aws_iam_role" "backend_lambda" {
  name = "selenia-back-dev-role-gyc0s5kg"
  path = "/service-role/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Managed policies attachments (las 2 AWS-managed; la 3ra customer-managed
# `AWSLambdaBasicExecutionRole-d5f5f9ec...` queda fuera de TF — redundante con
# la AWS-managed, eventualmente la podemos detach manualmente).
resource "aws_iam_role_policy_attachment" "backend_lambda_basic_exec" {
  role       = aws_iam_role.backend_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "backend_lambda_vpc_access" {
  role       = aws_iam_role.backend_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Inline policy con permisos sobre el bucket (agregada durante la sesión
# porque el code la necesita para los uploads).
resource "aws_iam_role_policy" "backend_lambda_s3_access" {
  name = "selenia-back-s3-access"
  role = aws_iam_role.backend_lambda.id

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
# 2. Lambda function (PackageType=Image, x86_64)
# ----------------------------------------------------------------------------
resource "aws_lambda_function" "backend" {
  function_name = "selenia-back-dev"
  role          = aws_iam_role.backend_lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.backend.repository_url}@${var.backend_lambda_image_digest}"
  architectures = ["x86_64"]
  memory_size   = 512
  timeout       = 60

  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.main.bucket
      S3_BUCKET_NAME = aws_s3_bucket.main.bucket
      DB_HOST        = aws_db_instance.main.address
      DB_USER        = var.db_username
      DB_PASSWORD    = var.db_password
      DB_NAME        = "selenia"
      DB_PORT        = "5432"
      OPENAI_API_KEY = var.openai_api_key
    }
  }

  vpc_config {
    subnet_ids = [
      aws_subnet.public_1.id,
      aws_subnet.public_2.id,
    ]
    security_group_ids = [
      aws_security_group.backend.id,
      aws_security_group.rds.id,
      "sg-0ac91a81b6bc5fe2e", # default SG del VPC (creada con el VPC, sin recurso TF)
    ]
  }

  tracing_config {
    mode = "PassThrough"
  }

  logging_config {
    log_format = "Text"
    log_group  = "/aws/lambda/selenia-back-dev"
  }
}

# ----------------------------------------------------------------------------
# 3. Permission para que el API Gateway invoque la Lambda
# ----------------------------------------------------------------------------
resource "aws_lambda_permission" "backend_apigw_invoke" {
  statement_id  = "a0272101-8c9d-530d-8736-e65791b3430b"
  function_name = aws_lambda_function.backend.function_name
  action        = "lambda:InvokeFunction"
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.backend.execution_arn}/*/*/{proxy+}"
}

# ----------------------------------------------------------------------------
# 4. API Gateway HTTP API (v2) con ruta proxy a la Lambda
# ----------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "backend" {
  name                         = "api-gateway-back-dev"
  protocol_type                = "HTTP"
  api_key_selection_expression = "$request.header.x-api-key"
  route_selection_expression   = "$request.method $request.path"
  disable_execute_api_endpoint = false
  ip_address_type              = "ipv4"
}

resource "aws_apigatewayv2_integration" "backend" {
  api_id                 = aws_apigatewayv2_api.backend.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  # HTTP API v2 con AWS_PROXY acepta el ARN plano del Lambda (no el invoke_arn
  # con el wrapper apigateway). Así fue creado a mano por el compañero.
  integration_uri = aws_lambda_function.backend.arn
  payload_format_version = "2.0"
  connection_type        = "INTERNET"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "backend_proxy" {
  api_id    = aws_apigatewayv2_api.backend.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.backend.id}"
}

resource "aws_apigatewayv2_stage" "backend_default" {
  api_id      = aws_apigatewayv2_api.backend.id
  name        = "$default"
  auto_deploy = true

  # Access logs configurados manualmente por el compañero. El log group
  # `api-gateway-trocha-dev` también es manual; queda fuera de TF por ahora
  # (no afecta funcionalidad; importarlo después si se quiere).
  access_log_settings {
    destination_arn = "arn:aws:logs:${var.region}:453794566331:log-group:api-gateway-trocha-dev"
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

# ----------------------------------------------------------------------------
# 5. VPC Endpoint S3 (Gateway type, gratis). Necesario para que la Lambda
#    pueda hablar con S3 sin salir a internet (Lambdas en VPC nunca tienen
#    IP pública incluso en subnets públicas).
# ----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
    }]
  })

  tags = {
    Name = "selenia-dev-s3-gateway"
  }
}

# ----------------------------------------------------------------------------
# Outputs útiles
# ----------------------------------------------------------------------------
output "backend_api_endpoint" {
  description = "URL del API Gateway HTTP API que sirve el backend"
  value       = aws_apigatewayv2_api.backend.api_endpoint
}

output "backend_lambda_arn" {
  description = "ARN de la Lambda del backend"
  value       = aws_lambda_function.backend.arn
}
