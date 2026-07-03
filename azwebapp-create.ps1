# Variables (customize these)
$RESOURCE_GROUP="myResourceGroup"
$LOCATION="eastus"
$APP_SERVICE_PLAN="myAppServicePlan"
$WEB_APP_NAME="myUniqueWebAppName123"  # must be globally unique

# 1. Create a resource group (skip if you already have one)
az group create `
  --name $RESOURCE_GROUP `
  --location $LOCATION

# 2. Create the App Service Plan with Free tier (F1)
az appservice plan create `
  --name $APP_SERVICE_PLAN `
  --resource-group $RESOURCE_GROUP `
  --location $LOCATION `
  --sku F1 `
  --is-linux    # remove this flag if you want Windows-based plan

# 3. Create the Web App
az webapp create `
  --name $WEB_APP_NAME `
  --resource-group $RESOURCE_GROUP `
  --plan $APP_SERVICE_PLAN `
  --runtime "NODE:20-lts"   # change runtime as needed
