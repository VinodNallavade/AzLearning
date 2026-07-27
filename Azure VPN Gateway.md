<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/adea1586-be22-4ba5-a8b0-99fe045d1856" />






# Azure Point-to-Site VPN Gateway Demo (PowerShell, SSTP)

Run this entire script in a **PowerShell** window — not bash/Git Bash/WSL. To confirm you're in the right shell, run `$PSVersionTable` first; if it errors, you're still in bash.

```powershell
#############################################################
# Azure Point-to-Site VPN Gateway Demo (PowerShell, SSTP)
#############################################################
$LOCATION = "eastus"
$RG = "rg-p2s-demo"
$ADMIN_USER = "azureadmin"
$ADMIN_PASS = "Azure@12345678!"   # consider generating at runtime instead

#############################################################
# Create Resource Group
#############################################################
az group create `
    --name $RG `
    --location $LOCATION

#############################################################
# Create VNet + GatewaySubnet
#############################################################
az network vnet create `
    --resource-group $RG `
    --name vnet-corporate `
    --address-prefix 10.10.0.0/16 `
    --subnet-name snet-web `
    --subnet-prefix 10.10.1.0/24

az network vnet subnet create `
    --resource-group $RG `
    --vnet-name vnet-corporate `
    --name GatewaySubnet `
    --address-prefix 10.10.255.0/27

#############################################################
# Public IP for the Gateway — MUST be zonal for AZ SKUs
#############################################################
az network public-ip create `
    --resource-group $RG `
    --name pip-vgw-corporate-az `
    --allocation-method Static `
    --sku Standard `
    --zone 1 2 3

#############################################################
# Generate Root Cert (self-signed, in the Windows cert store)
#############################################################
$rootCert = New-SelfSignedCertificate `
    -Type Custom `
    -KeySpec Signature `
    -Subject "CN=P2SRootCert" `
    -KeyExportPolicy Exportable `
    -HashAlgorithm sha256 `
    -KeyLength 2048 `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyUsageProperty Sign `
    -KeyUsage CertSign

#############################################################
# Export the Root Cert's public data as base64
# (this string goes into the Azure gateway config)
#############################################################
$rootCertBase64 = [System.Convert]::ToBase64String($rootCert.RawData)
$rootCertBase64 | Out-File -FilePath ".\P2SRootCertBase64.txt"

#############################################################
# Copy the Root Cert into Trusted Root store too
# (needed for the client to validate the chain when connecting)
#############################################################
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "CurrentUser")
$store.Open("ReadWrite")
$store.Add($rootCert)
$store.Close()

#############################################################
# Generate Client Cert, signed by the Root Cert
#############################################################
$clientCert = New-SelfSignedCertificate `
    -Type Custom `
    -DnsName "P2SClientCert" `
    -KeySpec Signature `
    -Subject "CN=P2SClientCert" `
    -KeyExportPolicy Exportable `
    -HashAlgorithm sha256 `
    -KeyLength 2048 `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -Signer $rootCert `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.2")

#############################################################
# Export the Client Cert as a .pfx
# (only needed if connecting from a DIFFERENT machine —
# this machine already has the cert in its local store)
#############################################################
$clientCertPassword = ConvertTo-SecureString -String "P2SClientPass123!" -Force -AsPlainText
Export-PfxCertificate -Cert $clientCert -FilePath ".\P2SClientCert.pfx" -Password $clientCertPassword

#############################################################
# Create the VPN Gateway with P2S config
# NOTE: this step takes ~30-45 minutes
# Using SSTP — Windows built-in VPN client, no extra app needed
#############################################################
az network vnet-gateway create `
    --resource-group $RG `
    --name vgw-corporate `
    --vnet vnet-corporate `
    --public-ip-address pip-vgw-corporate-az `
    --gateway-type Vpn `
    --vpn-type RouteBased `
    --sku VpnGw1AZ `
    --address-prefixes 172.16.0.0/24 `
    --client-protocol SSTP `
    --no-wait

az network vnet-gateway wait --resource-group $RG --name vgw-corporate --created

#############################################################
# Upload the Root Cert to the Gateway (trust anchor for P2S auth)
#############################################################
az network vnet-gateway root-cert create `
    --resource-group $RG `
    --gateway-name vgw-corporate `
    --name P2SRootCert `
    --public-cert-data $rootCertBase64

#############################################################
# Create a VM inside the VNet — no public IP, tunnel-only access
#############################################################
az vm create `
    -g $RG `
    -n vm-corp-web `
    --image Win2022Datacenter `
    --size Standard_B2s `
    --vnet-name vnet-corporate `
    --subnet snet-web `
    --public-ip-address "" `
    --private-ip-address 10.10.1.4 `
    --admin-username $ADMIN_USER `
    --admin-password $ADMIN_PASS

#############################################################
# Enable Ping on Windows Firewall
#############################################################
az vm run-command invoke `
    -g $RG `
    -n vm-corp-web `
    --command-id RunPowerShellScript `
    --scripts "Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In"

#############################################################
# Download the VPN client config
#############################################################
az network vnet-gateway vpn-client generate `
    --resource-group $RG `
    --name vgw-corporate `
    --authentication-method EAPTLS `
    --processor-architecture Amd64
```

## Notes

- **Shell requirement**: This script uses PowerShell syntax (`$var = value`, backtick `` ` `` line continuation, `New-SelfSignedCertificate`). It will fail with `command not found` errors if run in bash/Git Bash/WSL.
- **Run as Administrator**: `Export-PfxCertificate` and writing to the certificate store can fail under a non-elevated PowerShell session.
- **Cert chain**: The root cert is written to both `Cert:\CurrentUser\My` and `Cert:\CurrentUser\Root`. The second copy is required for the Windows VPN client to validate the certificate chain — without it you'll hit a "client certificate must include an issuer" error when connecting.
- **SSTP client**: Since this uses `--client-protocol SSTP`, no separate app install is needed. The downloaded VPN client zip will contain a setup executable that configures Windows' built-in VPN connection automatically.
- **Gateway provisioning time**: ~30–45 minutes. The `--no-wait` flag returns control immediately; the subsequent `wait` command blocks until provisioning finishes.
