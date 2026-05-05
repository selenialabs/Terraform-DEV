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

  user_data = <<-EOF
    #!/bin/bash
    set -e
    
    # Instalar Docker
    apt-get update -y
    apt-get install -y docker.io awscli
    systemctl enable docker
    systemctl start docker
    
    # Esperar a que docker esté listo
    sleep 5
    
    # Login a ECR
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.backend.repository_url}
    
    # Pull de la imagen
    docker pull ${aws_ecr_repository.backend.repository_url}:latest
    
    # Levantar el container con las variables de entorno
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

# Pipelines (Dagster)
resource "aws_instance" "pipelines" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = aws_key_pair.pipelines.key_name
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.pipelines.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  user_data = <<EOF
#!/bin/bash
set -e

apt-get update -y
apt-get install -y docker.io docker-compose-v2 awscli
systemctl enable docker
systemctl start docker
sleep 5

aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.pipelines.repository_url}

docker pull ${aws_ecr_repository.pipelines.repository_url}:ingestion-latest
docker pull ${aws_ecr_repository.pipelines.repository_url}:dagster-latest

mkdir -p /opt/pipelines
cd /opt/pipelines

# Crear dagster.yaml custom para dev
mkdir -p /opt/pipelines/dagster_home
cat > /opt/pipelines/dagster_home/dagster.yaml <<DAGSTERYAMLEOF
scheduler:
  module: dagster.core.scheduler
  class: DagsterDaemonScheduler
run_coordinator:
  module: dagster.core.run_coordinator
  class: QueuedRunCoordinator
  config:
    max_concurrent_runs: 2
storage:
  postgres:
    postgres_db:
      hostname: dagster-poc-postgres
      username:
        env: DAGSTER_POSTGRES_USER
      password:
        env: DAGSTER_POSTGRES_PASSWORD
      db_name:
        env: DAGSTER_POSTGRES_DB
      port: 5432
run_launcher:
  module: dagster_docker
  class: DockerRunLauncher
  config:
    image: ${aws_ecr_repository.pipelines.repository_url}:ingestion-latest
    network: pipelines_dagster_network
    container_kwargs:
      auto_remove: true
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock
        - /opt/pipelines/.env:/project/.env
DAGSTERYAMLEOF

cat > .env <<ENVEOF
DAGSTER_POSTGRES_USER=dagster
DAGSTER_POSTGRES_PASSWORD=dagster
DAGSTER_POSTGRES_DB=dagster
AWS_DB_HOST=${aws_db_instance.main.address}
AWS_DB_USER=${var.db_username}
AWS_DB_PASSWORD=${var.db_password}
AWS_DB_NAME=selenia
AWS_DB_PORT=5432
DB_HOST=${aws_db_instance.main.address}
DB_USER=${var.db_username}
DB_PASSWORD=${var.db_password}
DB_NAME=selenia
DB_PORT=5432
BUCKET_NAME=${aws_s3_bucket.main.bucket}
AWS_REGION=${var.region}
OPENAI_API_KEY=${var.openai_api_key}
DEPLOY_ENV=dev
ENVEOF

cat > docker-compose.yml <<COMPOSEEOF
services:
  dagster_db:
    image: postgres:16
    container_name: dagster_db
    hostname: dagster-poc-postgres
    environment:
      POSTGRES_USER: \$${DAGSTER_POSTGRES_USER}
      POSTGRES_PASSWORD: \$${DAGSTER_POSTGRES_PASSWORD}
      POSTGRES_DB: \$${DAGSTER_POSTGRES_DB}
    networks:
      - dagster_network

  ingestion_svc:
    image: ${aws_ecr_repository.pipelines.repository_url}:ingestion-latest
    container_name: ingestion_svc
    env_file:
      - .env
    restart: always
    networks:
      - dagster_network

  dagster_daemon:
    image: ${aws_ecr_repository.pipelines.repository_url}:dagster-latest
    container_name: dagster_daemon
    env_file:
      - .env
    entrypoint: ["dagster-daemon", "run"]
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/pipelines/dagster_home/dagster.yaml:/opt/dagster/dagster_home/dagster.yaml
    depends_on:
      - dagster_db
      - ingestion_svc
    networks:
      - dagster_network

  dagster_webserver:
    image: ${aws_ecr_repository.pipelines.repository_url}:dagster-latest
    container_name: dagster_webserver
    env_file:
      - .env
    entrypoint: ["dagster-webserver", "-h", "0.0.0.0", "-p", "3000", "-w", "workspace.yaml"]
    ports:
      - "3000:3000"
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/pipelines/dagster_home/dagster.yaml:/opt/dagster/dagster_home/dagster.yaml
    depends_on:
      - dagster_db
      - ingestion_svc
    networks:
      - dagster_network

networks:
  dagster_network:
    driver: bridge
COMPOSEEOF

# Permitir que el docker daemon dentro del container acceda a ECR
mkdir -p /root/.docker
aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.pipelines.repository_url}

docker compose up -d
EOF

  user_data_replace_on_change = true

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
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    
    # Instalar Docker
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    
    # Esperar a que docker esté listo
    sleep 5
    
    # Login a ECR
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.frontend.repository_url}
    
    # Pull de la imagen
    docker pull ${aws_ecr_repository.frontend.repository_url}:latest
    
    # Levantar el container
    docker run -d \
      --name frontend \
      --restart always \
      -p 8080:80 \
      ${aws_ecr_repository.frontend.repository_url}:latest
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