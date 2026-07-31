# Azure DNS - Official CLI Quickstarts (Combined)

## Overview

-   Public DNS Zone
-   Private DNS Zone with VNet auto-registration
-   Two Windows VMs
-   Manual DNS record creation
-   Validation using `ping` and `nslookup`

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/afed08da-174f-4a81-8393-23862fc16040" />


## Complete Bash Script

``` bash
#!/usr/bin/env bash
# =============================================================================
# Azure DNS - Official CLI Quickstarts, Combined
# Based on:
#   https://learn.microsoft.com/en-us/azure/dns/dns-getstarted-cli
#   https://learn.microsoft.com/en-us/azure/dns/private-dns-getstarted-cli
# =============================================================================
set -euo pipefail

# ----------------------------- VARIABLES ------------------------------------
LOCATION="eastus"

RG_PUBLIC="MyResourceGroup-dns-public"
ZONE_PUBLIC="contoso.azureweb"

RG_PRIVATE="MyResourceGroup-dns-private"
VNET="myAzureVNet"
SUBNET_BACKEND="backendSubnet"
ZONE_PRIVATE="private.contoso.com"
DNS_LINK="MyDNSLink"
VM1="myVM01"
VM2="myVM02"
ADMIN_USER="AzureAdmin"
ADMIN_PASS="P@ssw0rd123!"

az group create --name "$RG_PUBLIC" --location "$LOCATION"
az network dns zone create -g "$RG_PUBLIC" -n "$ZONE_PUBLIC"
az network dns record-set a add-record -g "$RG_PUBLIC" -z "$ZONE_PUBLIC" -n www -a 10.10.10.10

NS1=$(az network dns record-set ns show \
  --resource-group "$RG_PUBLIC" \
  --zone-name "$ZONE_PUBLIC" \
  --name @ \
  --query "NSRecords[0].nsdname" -o tsv)

#  ------ Test Public DNS--------------
nslookup www.$ZONE_PUBLIC $NS1

az group create --name "$RG_PRIVATE" --location "$LOCATION"

az network vnet create \
  --name "$VNET" \
  --resource-group "$RG_PRIVATE" \
  --location "$LOCATION" \
  --address-prefix 10.2.0.0/16 \
  --subnet-name "$SUBNET_BACKEND" \
  --subnet-prefixes 10.2.0.0/24

az network private-dns zone create \
  --resource-group "$RG_PRIVATE" \
  --name "$ZONE_PRIVATE"

az network private-dns link vnet create \
  --resource-group "$RG_PRIVATE" \
  --name "$DNS_LINK" \
  --zone-name "$ZONE_PRIVATE" \
  --virtual-network "$VNET" \
  --registration-enabled true

az vm create \
  --name "$VM1" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASS" \
  --resource-group "$RG_PRIVATE" \
  --location "$LOCATION" \
  --subnet "$SUBNET_BACKEND" \
  --vnet-name "$VNET" \
  --image Win2022Datacenter \
  --size Standard_B2s \
  --public-ip-address ""

az vm create \
  --name "$VM2" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASS" \
  --resource-group "$RG_PRIVATE" \
  --location "$LOCATION" \
  --subnet "$SUBNET_BACKEND" \
  --vnet-name "$VNET" \
  --image Win2022Datacenter \
  --size Standard_B2s \
  --public-ip-address ""

sleep 60

VM1_IP=$(az vm list-ip-addresses -g "$RG_PRIVATE" -n "$VM1" \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)

az network private-dns record-set a add-record \
  --resource-group "$RG_PRIVATE" \
  --zone-name "$ZONE_PRIVATE" \
  --record-set-name db \
  --ipv4-address "$VM1_IP"

FIREWALL_SCRIPT='New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Protocol ICMPv4'

az vm run-command invoke \
  --resource-group "$RG_PRIVATE" --name "$VM1" \
  --command-id RunPowerShellScript --scripts "$FIREWALL_SCRIPT"

az vm run-command invoke \
  --resource-group "$RG_PRIVATE" --name "$VM2" \
  --command-id RunPowerShellScript --scripts "$FIREWALL_SCRIPT"

PING_SCRIPT="ping myvm01.$ZONE_PRIVATE; ping db.$ZONE_PRIVATE"

az vm run-command invoke \
  --resource-group "$RG_PRIVATE" --name "$VM2" \
  --command-id RunPowerShellScript --scripts "$PING_SCRIPT" \
  --query "value[0].message" -o tsv
```

## Expected Validation

``` text
ping myvm01.private.contoso.com
ping db.private.contoso.com
```

Both DNS names resolve to the IP address of **myVM01**, demonstrating
automatic VM registration and a manually created service record.
