#############################################################
# Azure VNet Peering Demo
#############################################################

LOCATION="eastus"
RG="rg-network-demo"

ADMIN_USER="azureadmin"
ADMIN_PASS="Azure@12345678!"

#############################################################
# Create Resource Group
#############################################################

az group create \
    --name $RG \
    --location $LOCATION

#############################################################
# Create Corporate VNet
#############################################################

az network vnet create \
    --resource-group $RG \
    --name vnet-corporate \
    --address-prefix 10.10.0.0/16 \
    --subnet-name snet-web \
    --subnet-prefix 10.10.1.0/24

#############################################################
# Create Shared Services VNet
#############################################################

az network vnet create \
    --resource-group $RG \
    --name vnet-shared \
    --address-prefix 10.20.0.0/16 \
    --subnet-name snet-services \
    --subnet-prefix 10.20.1.0/24

#############################################################
# Create Corporate VM
#############################################################

az vm create \
    -g "$RG" \
    -n vm-corp-web \
    --image Win2022Datacenter \
    --size Standard_B2s \
    --vnet-name vnet-corporate \
    --subnet snet-web \
    --public-ip-address vm-corp-web-pip \
    --public-ip-sku Standard \
    --private-ip-address 10.10.1.4 \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASS"

#############################################################
# Create Shared Services VM
#############################################################

az vm create \
    -g "$RG" \
    -n vm-file-server \
    --image Win2022Datacenter \
    --size Standard_B2s \
    --vnet-name vnet-shared \
    --subnet snet-services \
    --public-ip-address vm-file-server-pip \
    --public-ip-sku Standard \
    --private-ip-address 10.20.1.4 \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASS"

#############################################################
# Enable Ping on Windows Firewall
#############################################################

az vm run-command invoke \
    -g "$RG" \
    -n vm-corp-web \
    --command-id RunPowerShellScript \
    --scripts "Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In"

az vm run-command invoke \
    -g "$RG" \
    -n vm-file-server \
    --command-id RunPowerShellScript \
    --scripts "Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In"


#############################################################
# Create Peering
#############################################################

az network vnet peering create \
    --resource-group $RG \
    --name Corporate-To-Shared \
    --vnet-name vnet-corporate \
    --remote-vnet vnet-shared \
    --allow-vnet-access

az network vnet peering create \
    --resource-group $RG \
    --name Shared-To-Corporate \
    --vnet-name vnet-shared \
    --remote-vnet vnet-corporate \
    --allow-vnet-access
