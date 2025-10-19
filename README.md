# iTop AMI con Packer y Terraform en AWS
Repositorio de prueba para construir una AMI personalizada de iTop usando Packer y lanzar una instancia EC2 con Terraform.

## 1. Configurar usuario de IAM en AWS

  1. `IAM` -> `Users` -> `Add user`
  2. Nombre de usuario: `your-username` -> Next
  3. Permissions options: Add user to group -> Next -> Create user
  4. Ve a `your-username`:
      - `Permissions` -> `Permissions policies`
      - `Add permissions` -> `Create inline policy` -> `JSON`
      - Ve a `/docs/packer-iam-policy.json`, copia el contenido y pégalo en el `Policy Editor`
      - Crea otra inline policy repitiendo el paso anterior pero esta vez:
        - Ve a `/docs/terraform-iam-policy.json`, copia el contenido y pégalo en el `Policy Editor`
  5. Ve a `your-username` -> `Security credentials` -> `Create access key`
      - Command line interface -> Next
      - Copia Access key ID y Secret access key
  6. En la terminal local ejecuta `aws configure` e ingresa las claves copiadas

Necesitarás ajustar estos valores según tu setup:
- `tu-ssh-keypair`: nombre de tu key pair
- `Packer`&`Terraform` instalado y configurado con `AWS CLI`
- Tener los permisos necesario para crear la infrastructura en AWS


## 2. Construir la AMI
```bash
# Inicializar plugins (primera vez)
packer init .

# Validar la configuración de Packer
packer validate .

# Construcción básica
packer build .

# O usando archivo de variables específico
packer build -var-file="variables.pkrvars.hcl" .
```

## 3. Lanzar la instancia
```bash
# Clonar el repositorio de Terraform
git clone https://github.com/keaguirre/terraform-itop-deploy

cd terraform-itop-deploy

# Inicializar Terraform
terraform init

# Aplicar la configuración (ajusta variables según tu setup)
terrafom apply --auto-approve -var="key_name=tu-ssh-keypair"

# Eliminar la infraestructura creada
terrafom destroy --auto-approve -var="key_name=tu-ssh-keypair"
```

## 4. Validación de la Instalación
Terraform al finalizar mostrará la IP pública de la instancia + el comando SSH para conectarse. Usa esa información para conectarte.

> [!NOTE]  
> Necesitarás la clave privada `.pem` asociada al key pair usado + permisos adecuados en el archivo `.pem`.
### Windows: 

  ```powershell
  # Quitar herencia de permisos
  icacls .\key.pem /inheritance:r

  # Conceder solo permiso de lectura al usuario actual (reemplaza permisos existentes para ese usuario)
  icacls .\key.pem /grant:r "$($env:USERNAME):R"

  # Verificar permisos
  icacls .\key.pem
```
### Linux:
```bash
# Ajustar permisos
chmod 400 ./key.pem

# Verificar permisos
ls -l ./key.pem 
```

## 5. Diagrama de Arquitectura
```mermaid
---
config:
  theme: default
  layout: dagre
---
flowchart RL
 subgraph SGA["SG-App (HTTP/HTTPS/SSH)"]
        APP["EC2 iTop"]
  end
 subgraph PUB1["Subred Publica"]
        IGW["Internet Gateway"]
        EIP["Elastic IP"]
        NAT["NAT Gateway"]
        SGA
  end
 subgraph SGR["SG-RDS (MySQL 3306 from SG-App)"]
        RDS["RDS MariaDB"]
  end
 subgraph SGVPC1["SG-SSM (HTTPS 443 from SG-App)"]
        EP1["VPC Endpoint<br>com.amazonaws.region.ssm"]
  end
 subgraph SGVPC2["SG-SSMMessages (HTTPS 443 from SG-App)"]
        EP2["VPC Endpoint<br>com.amazonaws.region.ssmmessages"]
  end
 subgraph SGVPC3["SG-EC2Messages (HTTPS 443 from SG-App)"]
        EP3["VPC Endpoint<br>com.amazonaws.region.ec2messages"]
  end
 subgraph SGEFS["SG-EFS (NFS 2049 from SG-App)"]
        EFS["EFS Storage"]
  end
 subgraph PRI1["Subred Privada"]
        SGR
        SGVPC1
        SGVPC2
        SGVPC3
        SGEFS
  end
 subgraph VPC["VPC"]
        PUB1
        PRI1
  end
 subgraph Monitoring["Monitoring & Recovery"]
        CW1["CloudWatch Alarm CRITICAL<br>StatusCheckFailed"]
        CW2["CloudWatch Alarm WARNING<br>HighCPU/Memory/Disk"]
        Lambda1["Lambda Auto-Recovery<br>Instance + EIP"]
        SNS["SNS Topic<br>Notifications"]
  end
    Cliente["Cliente Web"] --> Internet["Internet"]
    Internet --> IGW
    IGW --> EIP
    Route53["Route53 Health Check"] --> EIP
    EIP --> APP
    APP --> RDS & EFS & EP1 & EP2 & EP3 & CW1 & CW2
    PRI1 --> NAT
    NAT --> IGW
    CW1 -- "Auto-trigger" --> Lambda1
    CW2 -- Notification only --> SNS
    Lambda1 -- Creates new --> APP
    Lambda1 -- Associates --> EIP
    Lambda1 --> SNS
    SNS -- Manual trigger if needed --> Lambda1
    SSM["SSM Parameter Store"] --> EP1
    KMS["KMS"] --> SSM & RDS & EFS
    IAM["IAM Roles"] --> APP & Lambda1
```