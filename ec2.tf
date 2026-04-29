# ===== KEY PAIRS =====
# Generamos las claves SSH automáticamente con Terraform

resource "tls_private_key" "backend" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_private_key" "pipelines" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_private_key" "frontend" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "backend" {
  key_name   = "${var.project_name}-${var.environment}-backend-key"
  public_key = tls_private_key.backend.public_key_openssh
}

resource "aws_key_pair" "pipelines" {
  key_name   = "${var.project_name}-${var.environment}-pipelines-key"
  public_key = tls_private_key.pipelines.public_key_openssh
}

resource "aws_key_pair" "frontend" {
  key_name   = "${var.project_name}-${var.environment}-frontend-key"
  public_key = tls_private_key.frontend.public_key_openssh
}

# Guardar las claves privadas en archivos .pem locales
resource "local_file" "backend_key" {
  content         = tls_private_key.backend.private_key_pem
  filename        = "${path.module}/keys/backend-key.pem"
  file_permission = "0400"
}

resource "local_file" "pipelines_key" {
  content         = tls_private_key.pipelines.private_key_pem
  filename        = "${path.module}/keys/pipelines-key.pem"
  file_permission = "0400"
}

resource "local_file" "frontend_key" {
  content         = tls_private_key.frontend.private_key_pem
  filename        = "${path.module}/keys/frontend-key.pem"
  file_permission = "0400"
}

# ===== AMIs =====
# Buscamos automáticamente las AMIs más recientes

# Ubuntu 22.04 (para backend y pipelines)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Amazon Linux 2023 (para frontend)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ===== INSTANCIAS EC2 =====

# Backend
resource "aws_instance" "backend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.backend.key_name
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-backend"
    Role = "backend"
  }
}

# Pipelines (Dagster)
resource "aws_instance" "pipelines" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = aws_key_pair.pipelines.key_name
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.pipelines.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines"
    Role = "pipelines"
  }
}

# Frontend
resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.frontend.key_name
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.frontend.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend"
    Role = "frontend"
  }
}


# Elastic IPs para que las instancias tengan IP fija
resource "aws_eip" "backend" {
  instance = aws_instance.backend.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-backend-eip"
  }
}

resource "aws_eip" "pipelines" {
  instance = aws_instance.pipelines.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-pipelines-eip"
  }
}

resource "aws_eip" "frontend" {
  instance = aws_instance.frontend.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend-eip"
  }
}