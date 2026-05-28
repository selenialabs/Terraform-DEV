# Subnet group para la RDS (necesita al menos 2 subnets en distintas AZs).
# Incluimos las 4 subnets (públicas + privadas) porque AWS no permite remover
# del subnet group una subnet donde la RDS actualmente reside, sin downtime.
# La RDS sigue en una subnet pública hoy, pero `publicly_accessible=false`
# garantiza que no tiene IP pública ni DNS público — solo accesible vía
# DNS privado dentro de la VPC. Las subnets privadas quedan listas para que
# un futuro replica/restore o rotación de maintenance las use.
resource "aws_db_subnet_group" "main" {
  name = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id,
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  }
}

# Instancia RDS PostgreSQL
resource "aws_db_instance" "main" {
  identifier     = "${var.project_name}-${var.environment}-db"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp2"
  storage_encrypted     = true

  db_name  = "selenia"
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  skip_final_snapshot      = true
  deletion_protection      = false
  delete_automated_backups = true

  tags = {
    Name = "${var.project_name}-${var.environment}-db"
  }
}