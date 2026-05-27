# ===== KEY PAIRS =====
# Generamos las claves SSH automÃ¡ticamente con Terraform

resource "tls_private_key" "backend" {
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

resource "local_file" "frontend_key" {
  content         = tls_private_key.frontend.private_key_pem
  filename        = "${path.module}/keys/frontend-key.pem"
  file_permission = "0400"
}

# ===== AMIs =====
# Buscamos automÃ¡ticamente las AMIs mÃ¡s recientes

# Ubuntu 22.04 (para backend y pipelines) - AMI fijada
data "aws_ami" "ubuntu" {
  filter {
    name   = "image-id"
    values = ["ami-0ff290337e78c83bf"]
  }
}

# Amazon Linux 2023 (para frontend) - AMI fijada
data "aws_ami" "amazon_linux_2023" {
  filter {
    name   = "image-id"
    values = ["ami-03a4de20979bca479"]
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

  user_data = <<EOF
#!/bin/bash
set -e

apt-get update -y
apt-get install -y ca-certificates curl awscli cron
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker
sleep 5

aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.backend.repository_url}

docker pull ${aws_ecr_repository.backend.repository_url}:latest

docker run -d \
  --name backend \
  --restart always \
  -p 8000:8000 \
  -e S3_BUCKET_NAME=${aws_s3_bucket.main.bucket} \
  -e AWS_DEFAULT_REGION=${var.region} \
  -e DB_USER=${var.db_username} \
  -e DB_PASSWORD=${var.db_password} \
  -e DB_HOST=${aws_db_instance.main.address} \
  -e DB_PORT=5432 \
  -e DB_NAME=selenia \
  -e OPENAI_API_KEY=${var.openai_api_key} \
  ${aws_ecr_repository.backend.repository_url}:latest

cat > /usr/local/bin/ecr-login.sh <<ECREOF
#!/bin/bash
aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.backend.repository_url}
ECREOF
chmod +x /usr/local/bin/ecr-login.sh

systemctl enable cron
systemctl start cron

echo "0 */6 * * * root /usr/local/bin/ecr-login.sh" >> /etc/crontab

docker run -d \
  --name watchtower \
  --restart always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root/.docker:/root/.docker \
  -e DOCKER_CONFIG=/root/.docker \
  -e WATCHTOWER_POLL_INTERVAL=300 \
  -e WATCHTOWER_CLEANUP=true \
  -e WATCHTOWER_INCLUDE_STOPPED=false \
  -e DOCKER_API_VERSION=1.45 \
  containrrr/watchtower:1.7.1 \
  backend
EOF

  user_data_replace_on_change = true

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

# Frontend
resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.frontend.key_name
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.frontend.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  user_data = <<EOF
#!/bin/bash
set -e

dnf install -y docker awscli cronie
systemctl enable docker
systemctl start docker
sleep 5

aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.frontend.repository_url}

docker pull ${aws_ecr_repository.frontend.repository_url}:latest

docker run -d \
  --name frontend \
  --restart always \
  -p 8080:80 \
  ${aws_ecr_repository.frontend.repository_url}:latest

cat > /usr/local/bin/ecr-login.sh <<ECREOF
#!/bin/bash
aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.frontend.repository_url}
ECREOF
chmod +x /usr/local/bin/ecr-login.sh

systemctl enable crond
systemctl start crond

echo "0 */6 * * * root /usr/local/bin/ecr-login.sh" >> /etc/crontab

docker run -d \
  --name watchtower \
  --restart always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root/.docker:/root/.docker \
  -e DOCKER_CONFIG=/root/.docker \
  -e WATCHTOWER_POLL_INTERVAL=300 \
  -e WATCHTOWER_CLEANUP=true \
  -e WATCHTOWER_INCLUDE_STOPPED=false \
  -e DOCKER_API_VERSION=1.44 \
  containrrr/watchtower:1.7.1 \
  frontend
EOF

  user_data_replace_on_change = true

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

resource "aws_eip" "frontend" {
  instance = aws_instance.frontend.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend-eip"
  }
}
