# Azure Application Gateway Demo Lab — Path-Based Routing to App Service + VM

## Scenario Description

This setup mirrors a very common real-world cloud modernization pattern: a company is modernizing an application. The front end has moved to **Azure App Service** (two instances for redundancy and scale), but a **legacy API** still runs on a **Windows Virtual Machine** that has not been migrated yet. 

**Azure Application Gateway (WAF_v2)** sits in front of both and routes traffic based on URL path — so clients only ever see one single endpoint, one SSL certificate, and one WAF policy.

```
                               Internet
                                  │
                    Public IP (Standard, Static)
                                  │
                   ┌──── Application Gateway (WAF_v2) ────┐
                   │         Path-based routing           │
                   │                                      │
             "/"  (default)                          "/api/*"
                   │                                      │
       ┌───────────┴───────────┐                          │
       │                       │                       Windows VM (IIS)
  App Service #1          App Service #2               "vm-legacy-api"
   (primary)               (secondary)                private IP only
       │                       │                          │
       └── access-restricted to only accept traffic from ──┘
           the Application Gateway's Public IP
```

---

## Key Enterprise Design Controls

1. **Mixed Backend Architecture (PaaS + IaaS):** Single entry point routing traffic across modern serverless/PaaS web apps and legacy virtual machines.
2. **Web Application Firewall (WAF_v2):** Configured in **Prevention Mode** using OWASP 3.2 managed rule set for active attack mitigation (SQLi, XSS, RFI).
3. **Bypass Protection (IP Access Restrictions):** Azure App Services are locked down to accept traffic exclusively from the Application Gateway's public IP address (`403 Forbidden` on direct access attempts).
4. **Autoscaling:** Gateway scales dynamically (`--min-capacity 1` to `--max-capacity 3`) based on traffic load.
5. **Path-Based Routing Rules:**
   - `/api/*` → Legacy Windows VM (`appGatewayBackendPool` over HTTP 80)
   - `/` (Default) → Modern App Services (`pool-webapps` over HTTPS 443 with SNI hostname retention)

---

## Prerequisites

- **Azure CLI:** Logged in (`az login`) with an active Azure subscription.
- **Tools:** `zip` installed locally (used to package the web app content).
- **Permissions & Quota:** Sufficient quota for 1 App Service Plan (B1), 2 Web Apps, 1 Windows VM (Standard_B2s), and 1 App Gateway WAF_v2.

---

## Complete Azure CLI Deployment Script

```bash
#!/bin/bash
set -e

# ==============================================================================
# Step 1 — Variables
# ==============================================================================
RG="rg-appgw-demo"
LOCATION="eastus"

VNET="vnet-appgw-demo"
SUBNET_APPGW="subnet-appgw"
SUBNET_VM="subnet-vm"
NSG_VM="nsg-vm-appgw-demo"

PIP_APPGW="pip-appgw-demo"
APPGW="appgw-demo"
WAF_POLICY="wafpolicy-appgw-demo"

PLAN="asp-appgw-demo"
SUFFIX=$RANDOM
WEBAPP1="app-appgw-primary-$SUFFIX"
WEBAPP2="app-appgw-secondary-$SUFFIX"

VM="vm-legacy-api"
PIP_VM="pip-vm-legacy"
ADMIN_USER="azureadmin"
ADMIN_PASS="P@ssw0rd123!"   # ⚠️ CHANGE THIS before running in sensitive environments

# Fetch public IP dynamically to scope NSG RDP rule
MY_IP=$(curl -s https://api.ipify.org || echo "103.51.154.6")
echo "Your IP (used to scope RDP access): $MY_IP"

# ==============================================================================
# Step 2 — Resource group and networking
# ==============================================================================
echo "Creating Resource Group and Networking..."
az group create --name "$RG" --location "$LOCATION"

az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix 10.10.0.0/16 \
  --subnet-name "$SUBNET_APPGW" \
  --subnet-prefix 10.10.0.0/24

az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_VM" \
  --address-prefix 10.10.1.0/24

# Security rules: Allow HTTP only from AppGw subnet, RDP only from your public IP
az network nsg create --resource-group "$RG" --name "$NSG_VM"

az network nsg rule create \
  --resource-group "$RG" --nsg-name "$NSG_VM" \
  --name Allow-HTTP-From-AppGw \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --destination-port-ranges 80 \
  --source-address-prefixes 10.10.0.0/24

az network nsg rule create \
  --resource-group "$RG" --nsg-name "$NSG_VM" \
  --name Allow-RDP-MyIP \
  --priority 110 --direction Inbound --access Allow --protocol Tcp \
  --destination-port-ranges 3389 \
  --source-address-prefixes "$MY_IP"

az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET_VM" \
  --network-security-group "$NSG_VM"

# ==============================================================================
# Step 3 — Public IP + WAF policy
# ==============================================================================
echo "Creating Public IP and WAF Policy..."
az network public-ip create \
  --resource-group "$RG" --name "$PIP_APPGW" \
  --sku Standard --allocation-method Static --zone 1 2 3

az network application-gateway waf-policy create \
  --resource-group "$RG" --name "$WAF_POLICY"

az network application-gateway waf-policy managed-rule rule-set add \
  --resource-group "$RG" --policy-name "$WAF_POLICY" \
  --type OWASP --version 3.2

az network application-gateway waf-policy policy-setting update \
  --resource-group "$RG" --policy-name "$WAF_POLICY" \
  --state Enabled --mode Prevention

# ==============================================================================
# Step 4 — Two App Services (Modern Front-End)
# ==============================================================================
echo "Creating App Services..."
az appservice plan create \
  --resource-group "$RG" --name "$PLAN" --sku B1

az webapp create --resource-group "$RG" --plan "$PLAN" --name "$WEBAPP1"
az webapp create --resource-group "$RG" --plan "$PLAN" --name "$WEBAPP2"

# Prepare distinct web content for load balancing verification
mkdir -p /tmp/webapp1 /tmp/webapp2
echo "<h1>Hello from $WEBAPP1 (Primary)</h1>"   > /tmp/webapp1/index.html
echo "<h1>Hello from $WEBAPP2 (Secondary)</h1>" > /tmp/webapp2/index.html

( cd /tmp/webapp1 && zip -r ../webapp1.zip . )
( cd /tmp/webapp2 && zip -r ../webapp2.zip . )

az webapp deploy --resource-group "$RG" --name "$WEBAPP1" --src-path /tmp/webapp1.zip --type zip
az webapp deploy --resource-group "$RG" --name "$WEBAPP2" --src-path /tmp/webapp2.zip --type zip

# ==============================================================================
# Step 5 — Windows VM (Legacy API)
# ==============================================================================
echo "Creating Legacy Windows VM..."
az network public-ip create \
  --resource-group "$RG" --name "$PIP_VM" \
  --sku Standard --allocation-method Static

az network nic create \
  --resource-group "$RG" --name nic-vm-legacy \
  --vnet-name "$VNET" --subnet "$SUBNET_VM" \
  --public-ip-address "$PIP_VM" \
  --network-security-group "$NSG_VM"

az vm create \
  --resource-group "$RG" --name "$VM" \
  --nics nic-vm-legacy \
  --image Win2022Datacenter \
  --size Standard_B2s \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASS"

# Install IIS and configure /api route
IIS_SCRIPT='Install-WindowsFeature Web-Server -IncludeManagementTools; New-Item -Path C:\inetpub\wwwroot\api -ItemType Directory -Force; Set-Content -Path C:\inetpub\wwwroot\api\index.html -Value "<h1>Legacy VM API response</h1>"'

az vm run-command invoke \
  --resource-group "$RG" --name "$VM" \
  --command-id RunPowerShellScript \
  --scripts "$IIS_SCRIPT"

VM_PRIVATE_IP=$(az vm list-ip-addresses -g "$RG" -n "$VM" \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)
echo "VM private IP: $VM_PRIVATE_IP"

# ==============================================================================
# Step 6 — Create Application Gateway (WAF_v2, Autoscaling)
# ==============================================================================
echo "Creating Application Gateway..."
az network application-gateway create \
  --resource-group "$RG" --name "$APPGW" --location "$LOCATION" \
  --sku WAF_v2 \
  --min-capacity 1 --max-capacity 3 \
  --vnet-name "$VNET" --subnet "$SUBNET_APPGW" \
  --public-ip-address "$PIP_APPGW" \
  --waf-policy "$WAF_POLICY" \
  --priority 100 \
  --frontend-port 80 \
  --http-settings-port 80 --http-settings-protocol Http \
  --servers "$VM_PRIVATE_IP"

# ==============================================================================
# Step 7 — Backend Pools
# ==============================================================================
echo "Configuring Backend Pools..."
# Update default pool for Legacy VM
az network application-gateway address-pool update \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name appGatewayBackendPool \
  --servers "$VM_PRIVATE_IP"

# Create new pool for App Services
az network application-gateway address-pool create \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name pool-webapps \
  --servers "$WEBAPP1.azurewebsites.net" "$WEBAPP2.azurewebsites.net"

# ==============================================================================
# Step 8 — Health Probes
# ==============================================================================
echo "Creating Health Probes..."
# Explicit host avoids PickHostName conflict on HTTP settings without a host header
az network application-gateway probe create \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name probe-vm --protocol Http --path /api/ \
  --host 127.0.0.1 \
  --interval 30 --timeout 30 --threshold 3

# App Services probe using inherited settings from backend host
az network application-gateway probe create \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name probe-webapps --protocol Https --path / \
  --host-name-from-http-settings true \
  --interval 30 --timeout 30 --threshold 3 --match-status-codes 200-399

# ==============================================================================
# Step 9 — HTTP Settings
# ==============================================================================
echo "Updating HTTP Settings..."
# VM settings (plain HTTP, port 80)
az network application-gateway http-settings update \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name appGatewayBackendHttpSettings \
  --port 80 --protocol Http --probe probe-vm \
  --connection-draining-timeout 30

# App Service settings (HTTPS, port 443, required host header forwarding)
az network application-gateway http-settings create \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name settings-webapps \
  --port 443 --protocol Https --probe probe-webapps \
  --host-name-from-backend-pool true \
  --connection-draining-timeout 30

# ==============================================================================
# Step 10 — Path-Based Routing Rule
# ==============================================================================
echo "Setting up Path-Based Routing..."
az network application-gateway url-path-map create \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name pathmap-demo \
  --rule-name rule-legacy-api \
  --paths "/api/*" \
  --address-pool appGatewayBackendPool \
  --http-settings appGatewayBackendHttpSettings \
  --default-address-pool pool-webapps \
  --default-http-settings settings-webapps

az network application-gateway rule update \
  --resource-group "$RG" --gateway-name "$APPGW" \
  --name rule1 \
  --rule-type PathBasedRouting \
  --url-path-map pathmap-demo \
  --priority 100

# ==============================================================================
# Step 11 — Restrict App Services to Application Gateway IP Only
# ==============================================================================
echo "Locking down App Services..."
APPGW_PUBLIC_IP=$(az network public-ip show -g "$RG" -n "$PIP_APPGW" --query ipAddress -o tsv)

az webapp config access-restriction add \
  --resource-group "$RG" --name "$WEBAPP1" \
  --rule-name AllowAppGwOnly --action Allow \
  --ip-address "$APPGW_PUBLIC_IP/32" --priority 100

az webapp config access-restriction add \
  --resource-group "$RG" --name "$WEBAPP2" \
  --rule-name AllowAppGwOnly --action Allow \
  --ip-address "$APPGW_PUBLIC_IP/32" --priority 100

# ==============================================================================
# Step 12 — Summary Output
# ==============================================================================
VM_PUBLIC_IP=$(az network public-ip show -g "$RG" -n "$PIP_VM" --query ipAddress -o tsv)

echo ""
echo "============================================================"
echo " Deployment Complete!"
echo " Application Gateway public IP: $APPGW_PUBLIC_IP"
echo " VM private IP (legacy API):    $VM_PRIVATE_IP"
echo " VM public IP (for RDP):        $VM_PUBLIC_IP"
echo " Web App Primary:              $WEBAPP1"
echo " Web App Secondary:            $WEBAPP2"
echo "============================================================"
```

---

## Verification & Testing Guide

Run the following commands after deployment completes to verify configuration:

1. **Default Path Load Balancing (`/` → App Services):**
   ```bash
   for i in {1..4}; do curl -s "http://$APPGW_PUBLIC_IP/"; echo; done
   ```
   *Expected Result:* Alternates between `Primary` and `Secondary` App Service responses.

2. **Path-Based Routing (`/api/*` → Windows VM):**
   ```bash
   curl -s "http://$APPGW_PUBLIC_IP/api/"
   ```
   *Expected Result:* Returns `<h1>Legacy VM API response</h1>`.

3. **WAF Protection Test (Prevention Mode):**
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" "http://$APPGW_PUBLIC_IP/?id=1'%20OR%20'1'='1"
   ```
   *Expected Result:* `403 Forbidden` (Blocked by OWASP 3.2 SQLi rule set at gateway edge).

4. **Direct App Service Access Lockdown Check:**
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" "https://$WEBAPP1.azurewebsites.net/"
   ```
   *Expected Result:* `403 Forbidden` (Confirms App Service access restriction blocks direct bypass attempts).

5. **Legacy VM RDP Access:**
   ```bash
   mstsc /v:<VM_PUBLIC_IP>
   ```
   *Note:* Restricted by NSG rule to your source IP.

---

## Clean-Up Command

When you are finished testing, execute the following to tear down all resources:

```bash
az group delete --name "$RG" --yes --no-wait
```
