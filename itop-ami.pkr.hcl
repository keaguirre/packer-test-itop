packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
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
  default = "t3.medium"
  description = "Tipo de instancia para el build"
}

variable "ami_name_prefix" {
  type    = string
  default = "itop-server"
  description = "Prefijo para el nombre de la AMI"
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
    owners      = ["099720109477"] # Canonical
  }
 
  ssh_username = "ubuntu"
 
  # Configuración del volumen root
  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
  }
 
  tags = {
    Name = "${var.ami_name_prefix}-{{timestamp}}"
    Environment = "production"
    Application = "iTop"
    Built-with = "Packer"
    Built-on = "{{timestamp}}"
  }
}

# Build
build {
  name = "itop-ami"
  sources = ["source.amazon-ebs.ubuntu"]
 
  # Actualizar el sistema e instalar dependencias básicas
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y software-properties-common git curl"
    ]
  }
 
  # Agregar repositorio PPA de Ansible e instalar ansible-core
  provisioner "shell" {
    inline = [
      "sudo add-apt-repository --yes --update ppa:ansible/ansible",
      "sudo apt-get install -y ansible-core",
      "ansible --version",
      "echo 'Ansible instalado correctamente desde PPA oficial'"
    ]
  }

  # Instalar colecciones de Ansible globalmente para que sudo pueda usarlas
  provisioner "shell" {
    inline = [
      "echo 'Instalando colecciones de Ansible globalmente...'",
      "sudo ansible-galaxy collection install community.mysql",
      "sudo ansible-galaxy collection install community.general", 
      "sudo ansible-galaxy collection install ansible.posix",
      "echo 'Colecciones instaladas globalmente'",
      "sudo ansible-galaxy collection list"
    ]
  }
 
  # Ejecutar ansible-pull directamente desde el repositorio
  provisioner "shell" {
    inline = [
      "sudo ansible-pull \\",
      "  -U https://github.com/keaguirre/ansible-test-itop.git \\",
      "  -d /etc/ansible-itop \\",
      "  -i /etc/ansible-itop/inventory.ini \\",
      "  /etc/ansible-itop/site.yml"
    ]
  }
 
  # Verificar que la aplicación esté funcionando
  provisioner "shell" {
    inline = [
      "echo 'Verificando instalación de iTop...'",
      "sudo systemctl status apache2 || true",
      "sudo systemctl status mysql || true",
      "curl -I http://localhost/ || true",
      "echo 'Verificación completada'"
    ]
  }
 
  # Limpiar archivos temporales y logs
  provisioner "shell" {
     inline = [
       "sudo apt-get autoremove -y",
       "sudo apt-get autoclean", 
       "sudo rm -f /home/ubuntu/.bash_history",
       "sudo rm -f /var/log/cloud-init*.log",
       "sudo rm -f /var/log/auth.log*",
       "sudo rm -f /var/log/syslog*",
       "echo 'Limpieza completada - AMI lista para uso'"
     ]
  }
}