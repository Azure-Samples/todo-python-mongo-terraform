locals {
  tags                         = { azd-env-name : var.environment_name }
  sha                          = base64encode(sha256("${var.environment_name}${var.location}${data.azurerm_client_config.current.subscription_id}"))
  resource_token               = substr(replace(lower(local.sha), "[^A-Za-z0-9_]", ""), 0, 13)
  api_command_line             = "gunicorn --workers 4 --threads 2 --timeout 60 --access-logfile \"-\" --error-logfile \"-\" --bind=0.0.0.0:8000 -k uvicorn.workers.UvicornWorker todo.app:app"
  cosmos_connection_string_key = "AZURE-COSMOS-CONNECTION-STRING"
}
# ------------------------------------------------------------------------------------------------------
# Deploy resource Group
# ------------------------------------------------------------------------------------------------------
resource "azurecaf_name" "rg_name" {
  name          = var.environment_name
  resource_type = "azurerm_resource_group"
  random_length = 0
  clean_input   = true
}

resource "azurerm_resource_group" "rg" {
  name     = azurecaf_name.rg_name.result
  location = var.location

  tags = local.tags
}

# ------------------------------------------------------------------------------------------------------
# Deploy application insights
# ------------------------------------------------------------------------------------------------------
module "applicationinsights" {
  source           = "./modules/applicationinsights"
  location         = var.location
  rg_name          = azurerm_resource_group.rg.name
  environment_name = var.environment_name
  workspace_id     = module.loganalytics.LOGANALYTICS_WORKSPACE_ID
  tags             = azurerm_resource_group.rg.tags
  resource_token   = local.resource_token
}

# ------------------------------------------------------------------------------------------------------
# Deploy log analytics
# ------------------------------------------------------------------------------------------------------
module "loganalytics" {
  source         = "./modules/loganalytics"
  location       = var.location
  rg_name        = azurerm_resource_group.rg.name
  tags           = azurerm_resource_group.rg.tags
  resource_token = local.resource_token
}

# ------------------------------------------------------------------------------------------------------
# Deploy key vault
# ------------------------------------------------------------------------------------------------------
module "keyvault" {
  source                   = "./modules/keyvault"
  location                 = var.location
  principal_id             = var.principal_id
  rg_name                  = azurerm_resource_group.rg.name
  tags                     = azurerm_resource_group.rg.tags
  resource_token           = local.resource_token
  access_policy_object_ids = [module.api.IDENTITY_PRINCIPAL_ID]
  secrets = [
    {
      name  = local.cosmos_connection_string_key
      value = module.cosmos.AZURE_COSMOS_CONNECTION_STRING
    }
  ]
}

# ------------------------------------------------------------------------------------------------------
# Deploy cosmos
# ------------------------------------------------------------------------------------------------------
module "cosmos" {
  source         = "./modules/cosmos"
  location       = var.location
  rg_name        = azurerm_resource_group.rg.name
  tags           = azurerm_resource_group.rg.tags
  resource_token = local.resource_token
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service plan
# ------------------------------------------------------------------------------------------------------
module "appserviceplan" {
  source         = "./modules/appserviceplan"
  location       = var.location
  rg_name        = azurerm_resource_group.rg.name
  tags           = azurerm_resource_group.rg.tags
  resource_token = local.resource_token
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service web app
# ------------------------------------------------------------------------------------------------------
module "web" {
  source         = "./modules/appservicenode"
  location       = var.location
  rg_name        = azurerm_resource_group.rg.name
  resource_token = local.resource_token

  tags               = merge(local.tags, { azd-service-name : "web" })
  service_name       = "web"
  appservice_plan_id = module.appserviceplan.APPSERVICE_PLAN_ID
  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "false"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = module.applicationinsights.APPLICATIONINSIGHTS_CONNECTION_STRING
  }

  app_command_line = "pm2 serve /home/site/wwwroot --no-daemon --spa"
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service api
# ------------------------------------------------------------------------------------------------------
module "api" {
  source         = "./modules/appservicepython"
  location       = var.location
  rg_name        = azurerm_resource_group.rg.name
  resource_token = local.resource_token

  tags               = merge(local.tags, { "azd-service-name" : "api" })
  service_name       = "api"
  appservice_plan_id = module.appserviceplan.APPSERVICE_PLAN_ID
  app_settings = {
    "AZURE_COSMOS_CONNECTION_STRING_KEY"    = local.cosmos_connection_string_key
    "AZURE_COSMOS_DATABASE_NAME"            = module.cosmos.AZURE_COSMOS_DATABASE_NAME
    "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "true"
    "AZURE_KEY_VAULT_ENDPOINT"              = module.keyvault.AZURE_KEY_VAULT_ENDPOINT
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = module.applicationinsights.APPLICATIONINSIGHTS_CONNECTION_STRING
  }

  app_command_line = local.api_command_line
  identity = [{
    type = "SystemAssigned"
  }]
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service apim
# ------------------------------------------------------------------------------------------------------
module "apim"  {
  source                    = "./modules/apim"
  name                      = "apim-deployment"
  location                  = var.location
  rg_name                   = azurerm_resource_group.rg.name
  tags                      = merge(local.tags, { "azd-service-name" : var.environment_name })
  application_insights_name = local.resource_token
  sku                       = "Consumption"
} 

# ------------------------------------------------------------------------------------------------------
# Deploy app service apim-api
# ------------------------------------------------------------------------------------------------------
module "apimApi" {
  source                    = "./modules/apim-api"
  name                      = "apim-api-deployment"
  rg_name                   = azurerm_resource_group.rg.name
  apiName                   = "todo-api"
  apiDisplayName            = "Simple Todo API"
  apiPath                   = "todo"
}
