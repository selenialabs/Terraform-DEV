# ============================================================================
# Frontend en AWS Amplify (hosting de SPA + auto-build desde GitHub)
# ----------------------------------------------------------------------------
# Reemplaza la EC2 frontend (destruida) por Amplify Hosting. El compañero
# conectó el repo `selenialabs/front-end-mock` via OAuth de GitHub directamente
# desde la consola. Este archivo IMPORTA esos recursos a Terraform.
#
# Notas:
# - `access_token` / `oauth_token` no se pueden importar (AWS los almacena
#   encrypted y no los devuelve). Usamos `lifecycle.ignore_changes` para
#   evitar drift perpetuo. La conexión OAuth ya está establecida server-side.
# - `enable_branch_auto_build` está en false a nivel APP pero la BRANCH dev
#   tiene autoBuild=true. Es la config actual; matchea lo manual.
# - El env var VITE_API_URL apunta a la API Gateway del backend Lambda.
# ============================================================================

resource "aws_amplify_app" "frontend" {
  name       = "front-end-trocha-dev"
  platform   = "WEB"
  repository = "https://github.com/selenialabs/front-end-mock"

  enable_branch_auto_build    = false
  enable_branch_auto_deletion = false

  environment_variables = {
    VITE_API_URL = "https://2f8qpe9npg.execute-api.us-east-1.amazonaws.com"
  }

  build_spec = <<-EOT
    version: 1
    frontend:
      phases:
        preBuild:
          commands:
            - npm ci --cache .npm --prefer-offline
        build:
          commands:
            - npm run build
      artifacts:
        baseDirectory: dist
        files:
          - '**/*'
      cache:
        paths:
          - .npm/**/*
  EOT

  # SPA fallback: cualquier ruta sin extensión conocida sirve el index.html.
  custom_rule {
    source = "</^[^.]+$|\\.(?!(css|gif|ico|jpg|js|png|txt|svg|woff|woff2|ttf|map|json)$)([^.]+$)/>"
    target = "/index.html"
    status = "200"
  }

  lifecycle {
    # El OAuth token de GitHub no se puede importar — fue establecido via
    # la consola. Ignorar cambios para que terraform no rompa la conexión.
    ignore_changes = [access_token, oauth_token]
  }
}

resource "aws_amplify_branch" "frontend_dev" {
  app_id      = aws_amplify_app.frontend.id
  branch_name = "dev"
  framework   = "Web"
  stage       = "PRODUCTION"

  enable_auto_build = true
}
