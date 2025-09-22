# packer-test

# Validar la configuración
packer validate .

# Inicializar plugins (primera vez)
packer init .

# Construir la AMI
packer build .

# O usando archivo de variables específico
packer build -var-file="variables.pkrvars.hcl" .

# Listar las AMIs creadas
aws ec2 describe-images --owners self --query 'Images[?starts_with(Name, `itop-server`)].{Name:Name,ImageId:ImageId,CreationDate:CreationDate}' --output table

# Lanzar una instancia con la nueva AMI
aws ec2 run-instances \
  --image-id ami-xxxxxxxxx \
  --count 1 \
  --instance-type t3.medium \
  --key-name tu-key-pair \
  --security-group-ids sg-xxxxxxxxx \
  --subnet-id subnet-xxxxxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=iTop-Server}]'