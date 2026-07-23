#!/usr/bin/env bash
#############################################################################
# Azure VNet / Subnet / NSG / Service Tag demo — FULL BUILD SCRIPT
# Windows VMs, subnet-based rules (no ASGs), one-directional trust chain
# web -> app -> data, with explicit deny rules so nothing is left to the
# Azure default allow-within-VNet behavior.
#
# Run this with Azure CLI logged in (az login) and the right subscription
# selected (az account set --subscription "<name-or-id>").
#############################################################################

set -euo pipefail

#############################################
# 0. Variables (edit before running)
#############################################
RG="rg-netdemo"
LOCATION="eastus"
VNET="vnet-demo"
ADMIN_USER="azureadmin"
ADMIN_PASS="ReplaceWith-AStrongP@ssw0rd!"   # must meet Azure complexity rules
MY_IP="$(curl -s ifconfig.me)/32"           # your current public IP, for RDP access

#############################################
# 1. Resource group + VNet with 3 subnets
#############################################
az group create -n "$RG" -l "$LOCATION"

az network vnet create -g "$RG" -n "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name snet-web --subnet-prefix 10.0.1.0/24

az network vnet subnet create -g "$RG" --vnet-name "$VNET" \
  -n snet-app --address-prefix 10.0.2.0/24

az network vnet subnet create -g "$RG" --vnet-name "$VNET" \
  -n snet-data --address-prefix 10.0.3.0/24

#############################################
# 2. NSGs
#############################################
az network nsg create -g "$RG" -n nsg-web
az network nsg create -g "$RG" -n nsg-app
az network nsg create -g "$RG" -n nsg-data

#############################################
# 3. nsg-web rules
#############################################

# Inbound: allow HTTP/HTTPS from the internet
az network nsg rule create -g "$RG" --nsg-name nsg-web -n Allow-HTTP-Internet \
  --priority 100 --direction Inbound --access Allow \
  --source-address-prefixes Internet --destination-address-prefixes 10.0.1.0/24 \
  --destination-port-ranges 80 443 --protocol Tcp

# Inbound: allow RDP only from your own IP (management access)
az network nsg rule create -g "$RG" --nsg-name nsg-web -n Allow-RDP-MyIP \
  --priority 110 --direction Inbound --access Allow \
  --source-address-prefixes "$MY_IP" --destination-address-prefixes 10.0.1.0/24 \
  --destination-port-ranges 3389 --protocol Tcp

# Inbound: deny app and data subnets from initiating anything into web
# (enforces one-directional trust chain, prevents backward hops)
az network nsg rule create -g "$RG" --nsg-name nsg-web -n Deny-App-To-Web \
  --priority 300 --direction Inbound --access Deny \
  --source-address-prefixes 10.0.2.0/24 --destination-address-prefixes 10.0.1.0/24 \
  --destination-port-ranges '*' --protocol '*'

az network nsg rule create -g "$RG" --nsg-name nsg-web -n Deny-Data-To-Web \
  --priority 310 --direction Inbound --access Deny \
  --source-address-prefixes 10.0.3.0/24 --destination-address-prefixes 10.0.1.0/24 \
  --destination-port-ranges '*' --protocol '*'

# Outbound: deny web tier direct access to Storage / Key Vault
az network nsg rule create -g "$RG" --nsg-name nsg-web -n Deny-Out-Storage \
  --priority 200 --direction Outbound --access Deny \
  --source-address-prefixes 10.0.1.0/24 --destination-address-prefixes Storage \
  --destination-port-ranges 443 --protocol Tcp

az network nsg rule create -g "$RG" --nsg-name nsg-web -n Deny-Out-KeyVault \
  --priority 210 --direction Outbound --access Deny \
  --source-address-prefixes 10.0.1.0/24 --destination-address-prefixes AzureKeyVault \
  --destination-port-ranges 443 --protocol Tcp

#############################################
# 4. nsg-app rules
#############################################

# Inbound: allow app port 8080 only from web subnet
az network nsg rule create -g "$RG" --nsg-name nsg-app -n Allow-8080-FromWeb \
  --priority 100 --direction Inbound --access Allow \
  --source-address-prefixes 10.0.1.0/24 --destination-address-prefixes 10.0.2.0/24 \
  --destination-port-ranges 8080 --protocol Tcp

# Inbound: allow RDP only from web subnet (jump path, no public IP on VM2)
az network nsg rule create -g "$RG" --nsg-name nsg-app -n Allow-RDP-FromWeb \
  --priority 110 --direction Inbound --access Allow \
  --source-address-prefixes 10.0.1.0/24 --destination-address-prefixes 10.0.2.0/24 \
  --destination-port-ranges 3389 --protocol Tcp

# Inbound: deny data subnet from initiating anything back into app
az network nsg rule create -g "$RG" --nsg-name nsg-app -n Deny-Data-To-App \
  --priority 300 --direction Inbound --access Deny \
  --source-address-prefixes 10.0.3.0/24 --destination-address-prefixes 10.0.2.0/24 \
  --destination-port-ranges '*' --protocol '*'

# Outbound: allow app tier to Storage / Key Vault via service tags
az network nsg rule create -g "$RG" --nsg-name nsg-app -n Allow-Out-Storage \
  --priority 200 --direction Outbound --access Allow \
  --source-address-prefixes 10.0.2.0/24 --destination-address-prefixes Storage \
  --destination-port-ranges 443 --protocol Tcp

az network nsg rule create -g "$RG" --nsg-name nsg-app -n Allow-Out-KeyVault \
  --priority 210 --direction Outbound --access Allow \
  --source-address-prefixes 10.0.2.0/24 --destination-address-prefixes AzureKeyVault \
  --destination-port-ranges 443 --protocol Tcp

# Outbound: deny everything else to the open internet
az network nsg rule create -g "$RG" --nsg-name nsg-app -n Deny-Out-Internet \
  --priority 220 --direction Outbound --access Deny \
  --source-address-prefixes 10.0.2.0/24 --destination-address-prefixes Internet \
  --destination-port-ranges '*' --protocol '*'

#############################################
# 5. nsg-data rules
#############################################

# Inbound: allow SQL only from app subnet
az network nsg rule create -g "$RG" --nsg-name nsg-data -n Allow-SQL-FromApp \
  --priority 100 --direction Inbound --access Allow \
  --source-address-prefixes 10.0.2.0/24 --destination-address-prefixes 10.0.3.0/24 \
  --destination-port-ranges 1433 --protocol Tcp

# Inbound: allow RDP only from app subnet (jump path, no public IP on VM3)
az network nsg rule create -g "$RG" --nsg-name nsg-data -n Allow-RDP-FromApp \
  --priority 110 --direction Inbound --access Allow \
  --source-address-prefixes 10.0.2.0/24 --destination-address-prefixes 10.0.3.0/24 \
  --destination-port-ranges 3389 --protocol Tcp

# Inbound: deny web subnet from reaching data directly (skip-tier block — Test 5 fix)
az network nsg rule create -g "$RG" --nsg-name nsg-data -n Deny-Web-To-Data \
  --priority 300 --direction Inbound --access Deny \
  --source-address-prefixes 10.0.1.0/24 --destination-address-prefixes 10.0.3.0/24 \
  --destination-port-ranges '*' --protocol '*'

# Outbound: deny data tier direct access to Storage / Key Vault
az network nsg rule create -g "$RG" --nsg-name nsg-data -n Deny-Out-Storage \
  --priority 200 --direction Outbound --access Deny \
  --source-address-prefixes 10.0.3.0/24 --destination-address-prefixes Storage \
  --destination-port-ranges 443 --protocol Tcp

az network nsg rule create -g "$RG" --nsg-name nsg-data -n Deny-Out-KeyVault \
  --priority 210 --direction Outbound --access Deny \
  --source-address-prefixes 10.0.3.0/24 --destination-address-prefixes AzureKeyVault \
  --destination-port-ranges 443 --protocol Tcp

# Outbound: deny everything else to the open internet
az network nsg rule create -g "$RG" --nsg-name nsg-data -n Deny-Out-Internet \
  --priority 220 --direction Outbound --access Deny \
  --source-address-prefixes 10.0.3.0/24 --destination-address-prefixes Internet \
  --destination-port-ranges '*' --protocol '*'

#############################################
# 6. Associate NSGs to their subnets
#############################################
az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n snet-web --network-security-group nsg-web
az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n snet-app --network-security-group nsg-app
az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n snet-data --network-security-group nsg-data

#############################################
# 7. Windows VMs — pinned private IPs, only VM1 gets a public IP
#############################################
az vm create -g "$RG" -n vm-web --image Win2022Datacenter --size Standard_B2s \
  --vnet-name "$VNET" --subnet snet-web \
  --public-ip-address vm-web-pip --public-ip-sku Standard \
  --private-ip-address 10.0.1.4 \
  --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS"

az vm create -g "$RG" -n vm-app --image Win2022Datacenter --size Standard_B2s \
  --vnet-name "$VNET" --subnet snet-app --public-ip-address "" \
  --private-ip-address 10.0.2.4 \
  --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS"

az vm create -g "$RG" -n vm-db --image Win2022Datacenter --size Standard_B2s \
  --vnet-name "$VNET" --subnet snet-data --public-ip-address "" \
  --private-ip-address 10.0.3.4 \
  --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS"

#############################################
# 8. Storage account + Key vault (public endpoint, default)
#############################################
STORAGE_NAME="stnetdemo$RANDOM"
KV_NAME="kv-netdemo$RANDOM"

az storage account create -g "$RG" -n "$STORAGE_NAME" --sku Standard_LRS
az keyvault create -g "$RG" -n "$KV_NAME"

#############################################
# 9. Output — everything you need for the live demo tests
#############################################
WEB_PIP=$(az network public-ip show -g "$RG" -n vm-web-pip --query ipAddress -o tsv)

echo ""
echo "=================== DEMO RESOURCE SUMMARY ==================="
echo "VM1 (web)   public IP  : $WEB_PIP"
echo "VM1 (web)   private IP : 10.0.1.4"
echo "VM2 (app)   private IP : 10.0.2.4"
echo "VM3 (data)  private IP : 10.0.3.4"
echo "Storage acct URL       : $STORAGE_NAME.blob.core.windows.net"
echo "Key vault URL          : $KV_NAME.vault.azure.net"
echo "Admin username         : $ADMIN_USER"
echo "==============================================================="
