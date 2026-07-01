# ==========================================
# Variables
# ==========================================

$RG="rg-azure-demo"
$LOCATION="centralindia"

$VNET="vnet-demo"
$SUBNET="subnet-web"

$NSG="nsg-demo"

$PIP="pip-winvm01"

$NIC="nic-winvm01"

$VM="winvm01"

$USERNAME="azureadmin"
$PASSWORD="YourP@ssw0rd123!"

$IMAGE="Win2022Datacenter"

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
    --location $LOCATION `
    --address-prefix 10.0.0.0/16 `
    --subnet-name $SUBNET `
    --subnet-prefix 10.0.1.0/24

# ==========================================
# Create Network Security Group
# ==========================================

az network nsg create `
    --resource-group $RG `
    --name $NSG `
    --location $LOCATION

# ==========================================
# Allow RDP
# ==========================================

az network nsg rule create `
    --resource-group $RG `
    --nsg-name $NSG `
    --name Allow-RDP `
    --priority 100 `
    --direction Inbound `
    --access Allow `
    --protocol Tcp `
    --destination-port-ranges 3389

# ==========================================
# Create Public IP
# ==========================================

az network public-ip create `
    --resource-group $RG `
    --name $PIP `
    --location $LOCATION `
    --sku Standard `
    --allocation-method Static

# ==========================================
# Create Network Interface
# ==========================================

az network nic create `
    --resource-group $RG `
    --name $NIC `
    --location $LOCATION `
    --vnet-name $VNET `
    --subnet $SUBNET `
    --network-security-group $NSG `
    --public-ip-address $PIP

# ==========================================
# Create Windows Virtual Machine
# ==========================================

az vm create `
    --resource-group $RG `
    --name $VM `
    --location $LOCATION `
    --nics $NIC `
    --image $IMAGE `
    --size $SIZE `
    --admin-username $USERNAME `
    --admin-password $PASSWORD `
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
