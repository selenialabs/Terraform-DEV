# Bucket S3 principal
resource "aws_s3_bucket" "main" {
  bucket        = var.bucket_name
  force_destroy = true

  tags = {
    Name = "${var.project_name}-${var.environment}-bucket"
  }
}

# Versionado deshabilitado (igual que producción, asumido)
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Disabled"
  }
}

# Bloquear acceso público
resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Estructura de carpetas (objetos vacíos que simulan carpetas)
resource "aws_s3_object" "folders" {
  for_each = toset([
    "ventas/",
    "ventas_por_productos/",
    "productos/",
    "procesados/",
    "procesados/ventas/",
    "procesados/ventas_por_productos/",
    "procesados/productos/"
  ])

  bucket  = aws_s3_bucket.main.id
  key     = each.value
  content = ""
}