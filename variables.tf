variable "region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Nombre del entorno"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "selenia"
}

variable "my_ip" {
  description = "Tu IP pública para acceso SSH (formato CIDR)"
  type        = string
}

variable "db_username" {
  description = "Usuario master de la base de datos"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Contraseña master de la base de datos"
  type        = string
  sensitive   = true
}

variable "bucket_name" {
  description = "Nombre del bucket S3 (debe ser único globalmente)"
  type        = string
}

variable "openai_api_key" {
  description = "API key de OpenAI"
  type        = string
  sensitive   = true
}