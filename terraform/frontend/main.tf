terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# ============================================
# VARIABLES
# ============================================

variable "app_name" {
  type        = string
  description = "Application name (used for resource naming)"
}

variable "location" {
  type    = string
  default = "South India"
}

variable "project_type" {
  type        = string
  description = "Type of project: 'frontend'"
  default     = "frontend"
}

variable "backend_api_url" {
  type        = string
  description = "Backend API URL for frontend to connect to (single backend scenario)"
  default     = ""
}

variable "backend_urls" {
  type        = string
  description = "Comma-separated backend URLs (multiple backend scenario - triggers gateway creation)"
  default     = ""
}

variable "tier" {
  type        = string
  description = "Deployment tier: free, standard, premium"
  default     = "free"
}

# ============================================
# LOCALS
# ============================================

locals {
  resource_prefix = replace(
    replace(lower(var.app_name), "_", "-"),
    ".",
    "-"
  )
  is_frontend    = var.project_type == "frontend"
  create_gateway = var.backend_urls != "" && local.is_frontend
  gateway_sku    = var.tier == "premium" ? "S1" : var.tier == "standard" ? "B1" : "F1"
}

# ============================================
# RESOURCE GROUP
# ============================================

resource "azurerm_resource_group" "main" {
  name     = "${local.resource_prefix}-rg"
  location = var.location
}

# ============================================
# FRONTEND RESOURCES (Static Web App)
# ============================================

resource "azurerm_static_web_app" "main" {
  count               = local.is_frontend ? 1 : 0
  name                = "${local.resource_prefix}-static"
  resource_group_name = azurerm_resource_group.main.name
  location            = "eastasia"
  sku_tier            = "Free"
  sku_size            = "Free"

  depends_on = [azurerm_resource_group.main]
}

# ============================================
# GATEWAY RESOURCES (YARP Reverse Proxy)
# Created only when frontend has multiple backends
# ============================================

resource "azurerm_service_plan" "gateway" {
  count               = local.create_gateway ? 1 : 0
  name                = "${local.resource_prefix}-gateway-plan"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Windows"
  sku_name            = local.gateway_sku

  depends_on = [azurerm_resource_group.main]
}

resource "azurerm_windows_web_app" "gateway" {
  count               = local.create_gateway ? 1 : 0
  name                = "${local.resource_prefix}-gateway-webapp"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.gateway[0].id

  site_config {
    always_on = false
    application_stack {
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"
    "BACKEND_URLS"           = var.backend_urls
  }

  depends_on = [
    azurerm_resource_group.main,
    azurerm_service_plan.gateway
  ]
}

# ============================================
# OUTPUTS
# ============================================

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "project_type" {
  value = var.project_type
}

# Frontend outputs
output "static_webapp_name" {
  value = local.is_frontend ? azurerm_static_web_app.main[0].name : ""
}

output "static_webapp_url" {
  value = local.is_frontend ? "https://${azurerm_static_web_app.main[0].default_host_name}" : ""
}

output "static_webapp_api_key" {
  value     = local.is_frontend ? azurerm_static_web_app.main[0].api_key : ""
  sensitive = true
}

# Gateway outputs
output "gateway_webapp_name" {
  value = local.create_gateway ? azurerm_windows_web_app.gateway[0].name : ""
}

output "gateway_webapp_url" {
  value = local.create_gateway ? "https://${azurerm_windows_web_app.gateway[0].default_hostname}" : ""
}
