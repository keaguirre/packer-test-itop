packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

# Variables
variable "aws_region" {
  type    = string
  default = "us-east-1"
  description = "Región de AWS donde crear la AMI"
}

variable "instance_type" {
  type    = string
  default = "c5.large"
  description = "Tipo de instancia para el build - c5.large tiene CPU dedicada sin throttling"
}

variable "ami_name_prefix" {
  type    = string
  default = "itop-lab"
  description = "Prefijo para el nombre de la AMI"
}

variable "source_ami_owner" {
  type    = string
  default = "099720109477"
  description = "Owner de la AMI base (Canonical para Ubuntu)"
}

# Configuración de la fuente
source "amazon-ebs" "ubuntu" {
  ami_name      = "${var.ami_name_prefix}-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region
 
  # AMI base Ubuntu 22.04 LTS
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = [var.source_ami_owner]
  }
 
  ssh_username = "ubuntu"
  ssh_timeout  = "20m"
 
  # Configuración del volumen root optimizado
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size          = 20
    volume_type          = "gp3"
    iops                 = 3000
    throughput           = 125
    delete_on_termination = true
  }
 
  tags = {
    Name        = "${var.ami_name_prefix}-{{timestamp}}"
    Environment = "lab"
    Application = "iTop"
    Built-with  = "Packer"
    Built-on    = "{{timestamp}}"
    Version     = "1.0-lab"
  }
}

# Build
build {
  name = "itop-lab-ami"
  sources = ["source.amazon-ebs.ubuntu"]
  
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
 
  # Actualizar sistema base y habilitar repositorios
  provisioner "shell" {
    inline = [
      "echo 'Preparando APT y repositorios...'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get update -y || sudo apt-get update -y",
      "sudo add-apt-repository -y universe || true",
      "sudo apt-get update -y"
    ]
  }
 
  # Instalar dependencias básicas y NFS
  provisioner "shell" {
    inline = [
      "echo 'Instalando dependencias básicas...'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get install -y software-properties-common git curl nfs-common"
    ]
  }
  
  # Instalar dependencias de compilación para amazon-efs-utils
  provisioner "shell" {
    inline = [
      "echo 'Instalando dependencias de compilación...'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get install -y git binutils rustc cargo pkg-config libssl-dev"
    ]
  }
  
  # Compilar e instalar amazon-efs-utils
  provisioner "shell" {
    inline = [
      "echo 'Clonando repositorio de efs-utils...'",
      "cd /tmp",
      "git clone https://github.com/aws/efs-utils",
      "cd efs-utils",
      "echo 'Compilando paquete Debian con paralelismo máximo...'",
      "export CARGO_BUILD_JOBS=$(nproc)",
      "./build-deb.sh",
      "echo 'Instalando amazon-efs-utils...'",
      "sudo apt-get install -y ./build/amazon-efs-utils*deb",
      "echo 'Limpiando archivos temporales...'",
      "cd /tmp",
      "rm -rf efs-utils"
    ]
  }
 
  # Instalar Ansible desde PPA
  provisioner "shell" {
    inline = [
      "echo 'Instalando Ansible...'",
      "sudo add-apt-repository --yes --update ppa:ansible/ansible",
      "sudo apt-get install -y ansible-core",
      "ansible --version"
    ]
  }

  # Instalar colecciones de Ansible globalmente
  provisioner "shell" {
    inline = [
      "echo 'Instalando colecciones de Ansible...'",
      "sudo ansible-galaxy collection install community.mysql",
      "sudo ansible-galaxy collection install community.general", 
      "sudo ansible-galaxy collection install ansible.posix",
      "sudo ansible-galaxy collection list"
    ]
  }

  # Crear directorio para montaje EFS
  provisioner "shell" {
    inline = [
      "echo 'Preparando estructura de directorios...'",
      "sudo mkdir -p /var/www/html",
      "sudo chown ubuntu:ubuntu /var/www/html"
    ]
  }

  # Crear script helper para montaje EFS
  provisioner "shell" {
    inline = [
      "cat > /tmp/mount-efs.sh << 'EOFSCRIPT'",
      "#!/bin/bash",
      "# Helper script para montar EFS",
      "# Uso: sudo /usr/local/bin/mount-efs.sh <efs-id>",
      "",
      "if [ -z \"$1\" ]; then",
      "  echo \"Uso: $0 <efs-id>\"",
      "  echo \"Ejemplo: $0 fs-0123456789abcdef\"",
      "  exit 1",
      "fi",
      "",
      "EFS_ID=$1",
      "MOUNT_POINT=\"/var/www/html\"",
      "",
      "echo \"Montando EFS $EFS_ID en $MOUNT_POINT...\"",
      "",
      "# Montar EFS con amazon-efs-utils (soporta TLS)",
      "mount -t efs -o tls $EFS_ID:/ $MOUNT_POINT",
      "",
      "# Agregar a fstab si no existe",
      "if ! grep -q \"$EFS_ID\" /etc/fstab; then",
      "  echo \"$EFS_ID:/ $MOUNT_POINT efs defaults,_netdev,tls 0 0\" >> /etc/fstab",
      "  echo \"Agregado a /etc/fstab\"",
      "fi",
      "",
      "# Verificar",
      "if mountpoint -q $MOUNT_POINT; then",
      "  echo \"EFS montado correctamente\"",
      "  df -h | grep $MOUNT_POINT",
      "else",
      "  echo \"ERROR: Fallo al montar EFS\"",
      "  exit 1",
      "fi",
      "EOFSCRIPT",
      "sudo mv /tmp/mount-efs.sh /usr/local/bin/mount-efs.sh",
      "sudo chmod +x /usr/local/bin/mount-efs.sh"
    ]
  }

  # Crear script helper para ejecutar ansible-pull
  provisioner "shell" {
    inline = [
      "cat > /tmp/setup-itop.sh << 'EOFSCRIPT'",
      "#!/bin/bash",
      "# Helper script para ejecutar ansible-pull",
      "# Uso: sudo /usr/local/bin/setup-itop.sh",
      "",
      "REPO_URL=\"https://github.com/keaguirre/ansible-test-itop.git\"",
      "BRANCH=\"main\"",
      "",
      "echo \"Ejecutando Ansible para configurar iTop...\"",
      "",
      "ansible-pull -U \"$REPO_URL\" -C \"$BRANCH\" -d /etc/ansible-itop -i /etc/ansible-itop/inventory.ini /etc/ansible-itop/site.yml",
      "",
      "echo \"Configuración completada\"",
      "EOFSCRIPT",
      "sudo mv /tmp/setup-itop.sh /usr/local/bin/setup-itop.sh",
      "sudo chmod +x /usr/local/bin/setup-itop.sh"
    ]
  }

  # Limpieza final
  provisioner "shell" {
    inline = [
      "echo 'Limpiando sistema...'",
      "sudo apt-get autoremove -y",
      "sudo apt-get autoclean",
      "sudo rm -f /home/ubuntu/.bash_history",
      "sudo rm -f /var/log/cloud-init*.log",
      "sudo rm -f /var/log/auth.log*",
      "sudo rm -f /var/log/syslog*",
      "echo 'AMI lista para uso en lab'"
    ]
  }
}