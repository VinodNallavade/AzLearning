# ==========================================
# Variables
# ==========================================

$RG="rg-linux-demo"
$LOCATION="centralindia"

$VNET="vnet-demo"
$SUBNET="subnet-web"

$NSG="nsg-linux"

$PIP="pip-linuxvm01"

$NIC="nic-linuxvm01"

$VM="linuxvm01"

$USERNAME="azureuser"

$IMAGE="Ubuntu2404"

$SIZE="Standard_B1s"

# ==========================================
# Create Resource Group
# ==========================================

az group create `
    --name $RG `
    --location $LOCATION

# ==========================================
# Create Virtual Network
# ==========================================

az network vnet create `
    --resource-group $RG `
    --name $VNET `
    --address-prefix 10.0.0.0/16 `
    --subnet-name $SUBNET `
    --subnet-prefix 10.0.1.0/24

# ==========================================
# Create Network Security Group
# ==========================================

az network nsg create `
    --resource-group $RG `
    --name $NSG

# ==========================================
# Allow SSH
# ==========================================

az network nsg rule create `
    --resource-group $RG `
    --nsg-name $NSG `
    --name Allow-SSH `
    --priority 100 `
    --direction Inbound `
    --access Allow `
    --protocol Tcp `
    --destination-port-ranges 22

# ==========================================
# Create Static Public IP
# ==========================================

az network public-ip create `
    --resource-group $RG `
    --name $PIP `
    --sku Standard `
    --allocation-method Static

# ==========================================
# Create NIC
# ==========================================

az network nic create `
    --resource-group $RG `
    --name $NIC `
    --vnet-name $VNET `
    --subnet $SUBNET `
    --network-security-group $NSG `
    --public-ip-address $PIP

# ==========================================
# Create Linux VM
# ==========================================

az vm create `
    --resource-group $RG `
    --name $VM `
    --nics $NIC `
    --image $IMAGE `
    --size $SIZE `
    --admin-username $USERNAME `
    --generate-ssh-keys `
    --storage-sku StandardSSD_LRS

# ==========================================
# Show Public IP
# ==========================================

az vm show `
    --resource-group $RG `
    --name $VM `
    -d `
    --query publicIps `
    -o tsv
