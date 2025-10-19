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
  default = "c5.2xlarge"
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
      "REPO_URL=\"https://github.com/keaguirre/ansible-itop-setup.git\"",
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
    "set -euo pipefail",
    "",
    "log() { echo \"[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*\"; }",
    "",
    "MOUNT_POINT=\"/var/www/itop\"",
    "",
    "# --- Función: asegurar vhost de iTop habilitado ---",
    "ensure_itop_vhost() {",
    "  local VHOST=/etc/apache2/sites-available/itop.conf",
    "  # Crear vhost si falta",
    "  if [ ! -f \"$VHOST\" ]; then",
    "    cat > \"$VHOST\" <<'EOFVHOST'",
    "<VirtualHost *:80>",
    "    ServerName _",
    "    DocumentRoot /var/www/itop/web",
    "",
    "    <Directory /var/www/itop/web>",
    "        Options FollowSymLinks",
    "        AllowOverride All",
    "        Require all granted",
    "    </Directory>",
    "",
    "    DirectoryIndex index.php",
    "    ErrorLog $${APACHE_LOG_DIR}/itop-error.log",
    "    CustomLog $${APACHE_LOG_DIR}/itop-access.log combined",
    "</VirtualHost>",
    "EOFVHOST",
    "  fi",
    "",
    "  # Habilitar módulos y site correcto, deshabilitar default",
    "  a2enmod rewrite >/dev/null 2>&1 || true",
    "  [ -e /etc/apache2/sites-enabled/itop.conf ] || a2ensite itop.conf >/dev/null 2>&1 || true",
    "  [ ! -e /etc/apache2/sites-enabled/000-default.conf ] || a2dissite 000-default.conf >/dev/null 2>&1 || true",
    "}",
    "",
    "echo \"========================================\"",
    "log \"iTop Initialization Script (initialize-itop.sh)\"",
    "echo \"========================================\"",
    "",
    "# --- Verificar que EFS está montado ---",
    "if ! mountpoint -q \"$MOUNT_POINT\"; then",
    "  log \"ERROR: EFS no está montado en $MOUNT_POINT\"",
    "  log \"Sugerencia: sudo /usr/local/bin/mount-efs.sh <efs-id>\"",
    "  exit 1",
    "fi",
    "log \"✓ EFS montado en $MOUNT_POINT\"",
    "",
    "# --- Esperar a que el EFS tenga contenido (por latencias iniciales) ---",
    "WAIT_RETRIES=20",
    "SLEEP_SECONDS=6",
    "for i in $(seq 1 $WAIT_RETRIES); do",
    "  if [ \"$(ls -A \"$MOUNT_POINT\" 2>/dev/null)\" ]; then",
    "    log \"EFS ya tiene contenido (intento $${i})\"",
    "    break",
    "  fi",
    "  log \"EFS vacío (intento $${i}/$${WAIT_RETRIES})...\"",
    "  sleep $SLEEP_SECONDS",
    "  if [ \"$${i}\" -eq \"$${WAIT_RETRIES}\" ]; then",
    "    log \"ADVERTENCIA: EFS sin contenido tras $${WAIT_RETRIES} intentos. Continuando igualmente.\"",
    "  fi",
    "done",
    "",
    "# --- Detectar APP_ROOT (con o sin subcarpeta web) ---",
    "if [ -d \"$MOUNT_POINT/web\" ]; then",
    "  APP_ROOT=\"$MOUNT_POINT/web\"",
    "else",
    "  APP_ROOT=\"$MOUNT_POINT\"",
    "fi",
    "CONFIG_FILE=\"$APP_ROOT/conf/production/config-itop.php\"",
    "ITOP_MARKER=\"$APP_ROOT/pages/UI.php\"",
    "",
    "log \"APP_ROOT: $APP_ROOT\"",
    "log \"CONFIG_FILE: $CONFIG_FILE\"",
    "",
    "# --- Si ya existe configuración: asegurar vhost y recargar Apache ---",
    "if [ -f \"$CONFIG_FILE\" ]; then",
    "  log \"✓ iTop YA está configurado (config-itop.php presente)\"",
    "  log \"→ Asegurando vhost y recargando Apache...\"",
    "  ensure_itop_vhost",
    "  systemctl reload apache2 || systemctl restart apache2",
    "  log \"✓ Apache recargado\"",
    "  log \"Estado: LISTO | URL: http://$(hostname -I | awk '{print $1}')/\"",
    "  echo \"========================================\"",
    "  exit 0",
    "fi",
    "",
    "# --- Si no hay config, pero existe el árbol de iTop: ejecutar instalación ---",
    "if [ -f \"$ITOP_MARKER\" ]; then",
    "  log \"⚠ iTop detectado SIN configuración (primera instalación)\"",
    "else",
    "  log \"⚠ Árbol iTop no encontrado, procederá instalación igualmente\"",
    "fi",
    "",
    "log \"→ Ejecutando instalación con Ansible (install-itop.sh)...\"",
    "/usr/local/bin/install-itop.sh",
    "log \"✓ Instalación de iTop finalizada\"",
    "",
    "# Asegurar vhost para que el setup quede en la raíz",
    "ensure_itop_vhost",
    "systemctl reload apache2 || systemctl restart apache2",
    "log \"✓ Apache recargado\"",
    "log \"Estado: REQUIERE CONFIGURACIÓN | URL: http://$(hostname -I | awk '{print $1}')/setup/\"",
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