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
  
  # AMI base Ubuntu 22.04 LTS (verificar AMI ID actual en tu región)
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
  
  # Actualizar el sistema e instalar ansible
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y python3-pip git pipx git ansible-core",
      "pipx ensurepath",
    ]
  }
  
  # Copiar archivos de Ansible
  provisioner "file" {
    source = "../"
    destination = "/tmp/ansible-itop/"
  }
  
  # Crear inventario local para Packer
  provisioner "shell" {
    inline = [
      "cd /tmp/ansible-itop",
      "echo '[itop]' > inventory-local.ini",
      "echo 'localhost ansible_connection=local' >> inventory-local.ini"
    ]
  }
  
  # Ejecutar Ansible
  provisioner "ansible-local" {
    playbook_file = "../site.yml"
    inventory_file = "/tmp/ansible-itop/inventory-local.ini"
    extra_arguments = [
      "--extra-vars", "ansible_sudo_pass=''",
      "-v"
    ]
  }
  
  # Limpiar archivos temporales y logs
  provisioner "shell" {
    inline = [
      "sudo rm -rf /tmp/ansible-itop",
      "sudo apt-get autoremove -y",
      "sudo apt-get autoclean",
      "sudo rm -f /home/ubuntu/.bash_history",
      "sudo rm -f /var/log/cloud-init*.log",
      "sudo rm -f /var/log/auth.log*",
      "sudo rm -f /var/log/syslog*",
      "history -c"
    ]
  }
}