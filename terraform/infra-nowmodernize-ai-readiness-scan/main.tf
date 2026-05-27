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

variable "app_name" {
  type        = string
  description = "Application name (used for resource naming)"
}

variable "location" {
  type    = string
  default = "Central India"
}

variable "sql_admin_password" {
  type        = string
  description = "SQL Server admin password (optional - if not provided, SQL Server won't be created)"
  default     = ""
  sensitive   = true
}

variable "project_type" {
  type        = string
  description = "Type of project: 'backend' for .NET API, 'frontend' for React/Angular/Vue/Static"
  default     = "backend"
}

locals {
  resource_prefix = replace(
    replace(lower(var.app_name), "_", "-"),
    ".",
    "-"
  )
  create_sql_server = var.sql_admin_password != "" && var.project_type == "backend"
  is_frontend       = var.project_type == "frontend"
  is_backend        = var.project_type == "backend"
}

# Resource Group
resource "azurerm_resource_group" "main" {
  name     = "${local.resource_prefix}-rg"
  location = var.location
}

# ============================================
# BACKEND RESOURCES (Windows App Service)
# ============================================

# App Service Plan for Backend
resource "azurerm_service_plan" "main" {
  count               = local.is_backend ? 1 : 0
  name                = "${local.resource_prefix}-plan"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Windows"
  sku_name            = "F1"

  depends_on = [azurerm_resource_group.main]
}

# Windows Web App for Backend
resource "azurerm_windows_web_app" "main" {
  count               = local.is_backend ? 1 : 0
  name                = "${local.resource_prefix}-webapp"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main[0].id

  site_config {
    always_on = false
    application_stack {
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"
  }

  depends_on = [
    azurerm_resource_group.main,
    azurerm_service_plan.main
  ]
}

# SQL Server (conditional - backend only)
resource "azurerm_mssql_server" "main" {
  count                        = local.create_sql_server ? 1 : 0
  name                         = "${local.resource_prefix}-sqlserver"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = var.sql_admin_password

  depends_on = [azurerm_resource_group.main]
}

# SQL Database (conditional - backend only)
resource "azurerm_mssql_database" "main" {
  count     = local.create_sql_server ? 1 : 0
  name      = "${local.resource_prefix}-db"
  server_id = azurerm_mssql_server.main[0].id
  sku_name  = "Basic"

  depends_on = [
    azurerm_resource_group.main,
    azurerm_mssql_server.main
  ]
}

# SQL Server Firewall Rule (conditional - backend only)
resource "azurerm_mssql_firewall_rule" "allow_azure" {
  count            = local.create_sql_server ? 1 : 0
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"

  depends_on = [azurerm_mssql_server.main]
}

# ============================================
# FRONTEND RESOURCES (Static Web App)
# ============================================

# Azure Static Web App for Frontend
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
# OUTPUTS
# ============================================

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "project_type" {
  value = var.project_type
}

# Backend outputs
output "webapp_name" {
  value = local.is_backend ? azurerm_windows_web_app.main[0].name : ""
}

output "webapp_url" {
  value = local.is_backend ? "https://${azurerm_windows_web_app.main[0].default_hostname}" : ""
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
