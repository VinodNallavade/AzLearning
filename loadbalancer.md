# Standard Load Balancer Demo Lab (Azure CLI)

Demonstrates **both** inbound load balancing and outbound SNAT using a Standard Azure Load Balancer, with two Windows Server VMs running IIS as the backend pool.

## What This Lab Builds

- A resource group, VNet/subnet, and NSG (HTTP open to all, RDP restricted to your public IP)
- A Standard SKU public IP (zone-redundant)
- A Standard Load Balancer with:
  - An HTTP health probe (port 80)
  - An inbound load-balancing rule (`:80` → backend `:80`)
  - An explicit **outbound rule** for SNAT (since `disable-outbound-snat=true` is set on the inbound rule)
  - Two inbound NAT rules for per-VM RDP management (ports `50001` / `50002`)
- An availability set with 2 fault domains / 2 update domains
- Two NICs, each attached to the backend pool and one NAT rule
- Two Windows Server 2022 VMs (`vm-web1`, `vm-web2`) with IIS installed and a distinct `index.html` per VM, so you can visually confirm round-robin behavior

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Sufficient quota for 2x `Standard_B2s` VMs in the target region
- `curl` available locally (used to detect your public IP for the RDP NSG rule)

## ⚠️ Before You Run

- **Change `ADMIN_PASS`** — the placeholder password in the script must be replaced with a strong, unique password before deployment.
- **Region** — `LOCATION` defaults to `eastus`; change it to a region near you if needed.
- **RDP scoping** — the script auto-detects your public IP via `ifconfig.me` and restricts RDP (port 3389) to it. If your IP changes, you'll need to update the NSG rule.

![Uploading image.png…]()




## Script

```bash
#!/usr/bin/env bash
# =============================================================================
# Standard Load Balancer Demo Lab (Azure CLI)
# Demonstrates BOTH inbound load balancing and outbound SNAT
# Backend: 2x Windows Server VMs running IIS
# =============================================================================
set -euo pipefail

# ----------------------------- VARIABLES ------------------------------------
RG="rg-lb-demo"
LOCATION="eastus"                 # change to a region near you if needed
VNET="vnet-lb-demo"
SUBNET="subnet-web"
NSG="nsg-lb-demo"
PIP="pip-lb-demo"
LB="lb-demo"
BEPOOL="bepool-web"
PROBE="probe-http"
LBRULE="rule-http"
OUTRULE="outrule-snat"
AVSET="avset-lb-demo"
VM_SIZE="Standard_B2s"
ADMIN_USER="azureadmin"
ADMIN_PASS="ChangeThisP@ssw0rd123!"   # CHANGE THIS before running

# Restrict RDP to your own IP for safety. Leave as "*" only for a throwaway demo.
MY_IP="$(curl -s https://ifconfig.me)/32"

echo "Your detected public IP (used to scope RDP access): $MY_IP"

# ----------------------------- RESOURCE GROUP --------------------------------
az group create \
  --name "$RG" \
  --location "$LOCATION"

# ----------------------------- NETWORKING ------------------------------------
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET" \
  --subnet-prefix 10.0.1.0/24

az network nsg create \
  --resource-group "$RG" \
  --name "$NSG"

# Allow HTTP from anywhere (this is the public-facing app traffic)
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name Allow-HTTP \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes '*'

# Allow RDP only from your current IP (used via the LB's inbound NAT rules)
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name Allow-RDP-MyIP \
  --priority 110 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 3389 \
  --source-address-prefixes "$MY_IP"

# Attach NSG to subnet
az network vnet subnet update \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET" \
  --network-security-group "$NSG"

# ----------------------------- PUBLIC IP --------------------------------------
az network public-ip create \
  --resource-group "$RG" \
  --name "$PIP" \
  --sku Standard \
  --allocation-method Static \
  --zone 1 2 3

# ----------------------------- LOAD BALANCER -----------------------------------
az network lb create \
  --resource-group "$RG" \
  --name "$LB" \
  --sku Standard \
  --public-ip-address "$PIP" \
  --frontend-ip-name LoadBalancerFrontEnd \
  --backend-pool-name "$BEPOOL"

# Health probe - checks port 80 on each VM
az network lb probe create \
  --resource-group "$RG" \
  --lb-name "$LB" \
  --name "$PROBE" \
  --protocol Tcp \
  --port 80 \
  --interval 5 \
  --threshold 2

# Inbound load-balancing rule (public :80 -> backend :80)
# disable-outbound-snat=true because we define an explicit outbound rule below
az network lb rule create \
  --resource-group "$RG" \
  --lb-name "$LB" \
  --name "$LBRULE" \
  --protocol Tcp \
  --frontend-port 80 \
  --backend-port 80 \
  --frontend-ip-name LoadBalancerFrontEnd \
  --backend-pool-name "$BEPOOL" \
  --probe-name "$PROBE" \
  --disable-outbound-snat true \
  --idle-timeout 4

# Explicit outbound rule - this is what lets the VMs reach the internet,
# SNAT'd behind the LB's public IP
az network lb outbound-rule create \
  --resource-group "$RG" \
  --lb-name "$LB" \
  --name "$OUTRULE" \
  --frontend-ip-configs LoadBalancerFrontEnd \
  --backend-address-pool "$BEPOOL" \
  --protocol All \
  --idle-timeout 4 \
  --outbound-ports 10000

# Inbound NAT rules for RDP management (unique frontend port per VM)
az network lb inbound-nat-rule create \
  --resource-group "$RG" \
  --lb-name "$LB" \
  --name nat-rdp-vm1 \
  --protocol Tcp \
  --frontend-port 50001 \
  --backend-port 3389 \
  --frontend-ip-name LoadBalancerFrontEnd

az network lb inbound-nat-rule create \
  --resource-group "$RG" \
  --lb-name "$LB" \
  --name nat-rdp-vm2 \
  --protocol Tcp \
  --frontend-port 50002 \
  --backend-port 3389 \
  --frontend-ip-name LoadBalancerFrontEnd

# ----------------------------- AVAILABILITY SET --------------------------------
az vm availability-set create \
  --resource-group "$RG" \
  --name "$AVSET" \
  --platform-fault-domain-count 2 \
  --platform-update-domain-count 2

# ----------------------------- NICs ---------------------------------------------
az network nic create \
  --resource-group "$RG" \
  --name nic-vm1 \
  --vnet-name "$VNET" \
  --subnet "$SUBNET" \
  --lb-name "$LB" \
  --lb-address-pools "$BEPOOL" \
  --lb-inbound-nat-rules nat-rdp-vm1

az network nic create \
  --resource-group "$RG" \
  --name nic-vm2 \
  --vnet-name "$VNET" \
  --subnet "$SUBNET" \
  --lb-name "$LB" \
  --lb-address-pools "$BEPOOL" \
  --lb-inbound-nat-rules nat-rdp-vm2

# ----------------------------- VMs -----------------------------------------------
az vm create \
  --resource-group "$RG" \
  --name vm-web1 \
  --availability-set "$AVSET" \
  --nics nic-vm1 \
  --image Win2022Datacenter \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASS" \
  --no-wait

az vm create \
  --resource-group "$RG" \
  --name vm-web2 \
  --availability-set "$AVSET" \
  --nics nic-vm2 \
  --image Win2022Datacenter \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASS" \
  --no-wait

echo "Waiting for both VMs to finish provisioning..."
az vm wait --resource-group "$RG" --name vm-web1 --created
az vm wait --resource-group "$RG" --name vm-web2 --created

# ----------------------------- INSTALL IIS + DISTINCT PAGE -----------------------
# Each VM gets its own hostname baked into index.html so you can visually
# confirm the load balancer is alternating between backends.

IIS_SCRIPT_VM1='Install-WindowsFeature -Name Web-Server -IncludeManagementTools; Set-Content -Path C:\inetpub\wwwroot\index.html -Value "<h1>Hello from VM-WEB1</h1>"'
IIS_SCRIPT_VM2='Install-WindowsFeature -Name Web-Server -IncludeManagementTools; Set-Content -Path C:\inetpub\wwwroot\index.html -Value "<h1>Hello from VM-WEB2</h1>"'

az vm run-command invoke \
  --resource-group "$RG" \
  --name vm-web1 \
  --command-id RunPowerShellScript \
  --scripts "$IIS_SCRIPT_VM1"

az vm run-command invoke \
  --resource-group "$RG" \
  --name vm-web2 \
  --command-id RunPowerShellScript \
  --scripts "$IIS_SCRIPT_VM2"

# ----------------------------- SUMMARY -------------------------------------------
LB_PUBLIC_IP=$(az network public-ip show -g "$RG" -n "$PIP" --query ipAddress -o tsv)

echo ""
echo "============================================================"
echo "Lab deployed. Load Balancer public IP: $LB_PUBLIC_IP"
echo ""
echo "TEST INBOUND (round robin):"
echo "  for i in 1 2 3 4 5 6; do curl -s http://$LB_PUBLIC_IP; echo; done"
echo ""
echo "TEST RDP MANAGEMENT (per-VM via NAT rules):"
echo "  mstsc /v:$LB_PUBLIC_IP:50001   # -> vm-web1"
echo "  mstsc /v:$LB_PUBLIC_IP:50002   # -> vm-web2"
echo ""
echo "TEST OUTBOUND SNAT (run inside an RDP session, in a browser or PowerShell):"
echo "  (Invoke-WebRequest -Uri 'https://ifconfig.me').Content"
echo "  -> Should return: $LB_PUBLIC_IP"
echo ""
echo "CLEAN UP WHEN DONE:"
echo "  az group delete --name $RG --yes --no-wait"
echo "============================================================"
```

## Testing the Lab

**Inbound round-robin:**
```bash
for i in 1 2 3 4 5 6; do curl -s http://<LB_PUBLIC_IP>; echo; done
```
You should see the response alternate between "Hello from VM-WEB1" and "Hello from VM-WEB2".

**RDP management (per-VM):**
```
mstsc /v:<LB_PUBLIC_IP>:50001   # -> vm-web1
mstsc /v:<LB_PUBLIC_IP>:50002   # -> vm-web2
```

**Outbound SNAT** — from inside an RDP session, run:
```powershell
(Invoke-WebRequest -Uri 'https://ifconfig.me').Content
```
The result should match the load balancer's public IP.

## Cleanup

```bash
az group delete --name rg-lb-demo --yes --no-wait
```
