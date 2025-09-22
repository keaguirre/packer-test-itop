# packer-test

# Validar la configuración
packer validate .

# Inicializar plugins (primera vez)
packer init .

# Construir la AMI
packer build .

# O usando archivo de variables específico
packer build -var-file="variables.pkrvars.hcl" .