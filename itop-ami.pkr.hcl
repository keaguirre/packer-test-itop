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
  default = "us-east-2"
  description = "Región de AWS donde crear la AMI"
}

variable "instance_type" {
  type    = string
  default = "c5.large"
  description = "Tipo de instancia para el build"
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
 
  # Instalar dependencias del sistema base
  provisioner "shell" {
    inline = [
      "echo 'Instalando dependencias básicas del sistema...'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get install -y software-properties-common git curl nfs-common wget unzip"
    ]
  }
  
  # Instalar Apache y PHP (stack LAMP para iTop)
  provisioner "shell" {
    inline = [
      "echo 'Instalando Apache y PHP...'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get install -y apache2 libapache2-mod-php",
      "sudo apt-get install -y php php-cli php-mysql php-ldap php-soap php-xml php-zip php-gd php-mbstring php-curl",
      "echo 'Habilitando módulos de Apache...'",
      "sudo a2enmod rewrite",
      "sudo a2enmod php8.1 || sudo a2enmod php8.2 || sudo a2enmod php"
    ]
  }

    # Drop-in systemd para que Apache espere a que /var/www/itop esté montado (EFS)
  provisioner "shell" {
    inline = [
      "echo 'Creando drop-in de systemd para que Apache espere el EFS (/var/www/itop)...'",
      "SVC='apache2'; systemctl list-unit-files | grep -q '^httpd.service' && SVC='httpd'",

      # Crear carpeta del drop-in según el servicio detectado
      "sudo mkdir -p /etc/systemd/system/$SVC.service.d",

      # Escribir el drop-in
      "sudo tee /etc/systemd/system/$SVC.service.d/efs-wait.conf >/dev/null <<'EOF'",
      "[Unit]",
      "After=network-online.target remote-fs.target",
      "RequiresMountsFor=/var/www/itop",
      "EOF",

      # (Opcional) asegurar que el wait-online esté disponible/activo (no rompe si no existe)
      "sudo systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true",

      # Recargar systemd y habilitar el servicio web para el próximo boot
      "sudo systemctl daemon-reload",
      "sudo systemctl enable $SVC",

      # Mostrar cómo quedó
      "echo '--- systemd drop-in ---'",
      "sudo systemctl cat $SVC | sed -n '1,200p'"
    ]
  }


  # Instalar MariaDB client (para conectarse a RDS)
  provisioner "shell" {
    inline = [
      "echo 'Instalando cliente MySQL...'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get install -y mariadb-client"
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

  # Crear estructura de directorios con permisos correctos
  provisioner "shell" {
    inline = [
      "echo 'Preparando estructura de directorios...'",
      "sudo mkdir -p /var/www/itop",
      "sudo chown www-data:www-data /var/www/itop",
      "sudo chmod 755 /var/www/itop",
      "echo 'Directorio preparado (será sobremontado por EFS)'"
    ]
  }

  # Script 1: Montar EFS (solo montaje, no modifica contenido)
  provisioner "shell" {
    inline = [
      "cat > /tmp/mount-efs.sh << 'EOFSCRIPT'",
      "#!/bin/bash",
      "set -e",
      "",
      "if [ -z \"$1\" ]; then",
      "  echo \"Uso: $0 <efs-id> [region]\"",
      "  echo \"Ejemplo: $0 fs-0123456789abcdef us-east-2\"",
      "  exit 1",
      "fi",
      "",
      "EFS_ID=$1",
      "AWS_REGION=$${2:-us-east-2}",
      "MOUNT_POINT=\"/var/www/itop\"",
      "",
      "echo \"[$(date)] Montando EFS $EFS_ID en $MOUNT_POINT...\"",
      "",
      "# Verificar que el punto de montaje existe",
      "if [ ! -d \"$MOUNT_POINT\" ]; then",
      "  echo \"ERROR: $MOUNT_POINT no existe\"",
      "  exit 1",
      "fi",
      "",
      "# Verificar si ya está montado",
      "if mountpoint -q \"$MOUNT_POINT\"; then",
      "  echo \"ADVERTENCIA: $MOUNT_POINT ya está montado\"",
      "  df -h | grep $MOUNT_POINT",
      "  exit 0",
      "fi",
      "",
      "# Montar EFS con TLS",
      "mount -t efs -o tls \"$EFS_ID:/\" \"$MOUNT_POINT\"",
      "",
      "# Agregar a fstab si no existe",
      "if ! grep -q \"$EFS_ID\" /etc/fstab; then",
      "  echo \"$EFS_ID:/ $MOUNT_POINT efs defaults,_netdev,tls 0 0\" >> /etc/fstab",
      "  echo \"Entrada agregada a /etc/fstab\"",
      "fi",
      "",
      "# Verificar montaje exitoso",
      "if mountpoint -q \"$MOUNT_POINT\"; then",
      "  echo \"[$(date)] EFS montado exitosamente\"",
      "  df -h | grep $MOUNT_POINT",
      "  ",
      "  # Asegurar permisos correctos (sin modificar contenido existente)",
      "  chown www-data:www-data \"$MOUNT_POINT\"",
      "  chmod 755 \"$MOUNT_POINT\"",
      "  ",
      "  echo \"Contenido actual:\"",
      "  ls -la \"$MOUNT_POINT\" | head -10",
      "else",
      "  echo \"ERROR: Fallo al montar EFS\"",
      "  exit 1",
      "fi",
      "EOFSCRIPT",
      "sudo mv /tmp/mount-efs.sh /usr/local/bin/mount-efs.sh",
      "sudo chmod +x /usr/local/bin/mount-efs.sh"
    ]
  }

  # Script 2: Instalar iTop con Ansible (solo instalación)
  provisioner "shell" {
    inline = [
      "cat > /tmp/install-itop.sh << 'EOFSCRIPT'",
      "#!/bin/bash",
      "set -e",
      "",
      "REPO_URL=\"https://github.com/keaguirre/ansible-test-itop.git\"",
      "BRANCH=\"main\"",
      "DEST_DIR=\"/etc/ansible-itop\"",
      "",
      "echo \"[$(date)] Instalando iTop con Ansible...\"",
      "",
      "# Ejecutar ansible-pull",
      "ansible-pull \\",
      "  -U \"$REPO_URL\" \\",
      "  -C \"$BRANCH\" \\",
      "  -d \"$DEST_DIR\" \\",
      "  -i \"$DEST_DIR/inventory.ini\" \\",
      "  \"$DEST_DIR/site.yml\"",
      "",
      "echo \"[$(date)] Instalación de iTop completada\"",
      "EOFSCRIPT",
      "sudo mv /tmp/install-itop.sh /usr/local/bin/install-itop.sh",
      "sudo chmod +x /usr/local/bin/install-itop.sh"
    ]
  }

  # Script 3: Inicialización inteligente optimizada
  provisioner "shell" {
    inline = [
      "cat > /tmp/initialize-itop.sh << 'EOFSCRIPT'",
      "#!/bin/bash",
      "set -e",
      "",
      "MOUNT_POINT=\"/var/www/itop\"",
      "ITOP_MARKER=\"$MOUNT_POINT/web/pages/UI.php\"",
      "",
      "echo \"========================================\"",
      "echo \"iTop Initialization Script\"",
      "echo \"$(date)\"",
      "echo \"========================================\"",
      "",
      "# Verificar que EFS está montado",
      "if ! mountpoint -q \"$MOUNT_POINT\"; then",
      "  echo \"ERROR: EFS no está montado en $MOUNT_POINT\"",
      "  echo \"Ejecuta: sudo /usr/local/bin/mount-efs.sh <efs-id>\"",
      "  exit 1",
      "fi",
      "",
      "echo \"✓ EFS montado correctamente\"",
      "echo \"\"",
      "",
      "# Verificar si iTop ya existe",
      "if [ -f \"$ITOP_MARKER\" ]; then",
      "  echo \"✓ iTop YA existe en EFS\"",
      "  echo \"→ Solo reiniciando Apache...\"",
      "  systemctl restart apache2",
      "  echo \"✓ Apache reiniciado\"",
      "  echo \"\"",
      "  echo \"Estado: LISTO\"",
      "  echo \"URL: http://$(hostname -I | awk '{print $1}')/\"",
      "else",
      "  echo \"⚠ iTop NO encontrado (primera instalación)\"",
      "  echo \"→ Ejecutando instalación con Ansible...\"",
      "  echo \"\"",
      "  /usr/local/bin/install-itop.sh",
      "  echo \"\"",
      "  echo \"✓ Instalación completada\"",
      "  echo \"Estado: REQUIERE CONFIGURACIÓN\"",
      "  echo \"URL: http://$(hostname -I | awk '{print $1}')/setup/\"",
      "fi",
      "",
      "echo \"========================================\"",
      "EOFSCRIPT",
      "sudo mv /tmp/initialize-itop.sh /usr/local/bin/initialize-itop.sh",
      "sudo chmod +x /usr/local/bin/initialize-itop.sh"
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