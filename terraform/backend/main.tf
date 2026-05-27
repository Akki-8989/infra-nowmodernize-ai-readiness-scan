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

variable "sql_admin_password" {
  type        = string
  description = "Database admin password (optional - used for any database type)"
  default     = ""
  sensitive   = true
}

variable "project_type" {
  type        = string
  description = "Type of project: 'backend'"
  default     = "backend"
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

variable "runtime_stack" {
  type        = string
  description = "Runtime stack: dotnet, node, python, java"
  default     = "dotnet"
}

variable "database_type" {
  type        = string
  description = "Database type: none, sqlserver, postgresql, mysql"
  default     = "none"
}

variable "database_name" {
  type        = string
  description = "Database name to create (optional - auto-generated if empty)"
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

  # Tier-based SKU
  sku_name  = var.tier == "premium" ? "S1" : var.tier == "standard" ? "B1" : "F1"
  always_on = var.tier != "free"

  # Runtime conditions
  is_dotnet  = var.runtime_stack == "dotnet"
  is_linux   = !local.is_dotnet

  # Database conditions
  create_sql_server  = var.database_type == "sqlserver" && var.sql_admin_password != ""
  create_postgresql   = var.database_type == "postgresql" && var.sql_admin_password != ""
  create_mysql        = var.database_type == "mysql" && var.sql_admin_password != ""
  has_database        = local.create_sql_server || local.create_postgresql || local.create_mysql
  effective_db_name   = var.database_name != "" ? var.database_name : "${local.resource_prefix}-db"

  # Backend flag
  is_backend = var.project_type == "backend"

  # Connection string (computed after DB resources)
  connection_string = (
    local.create_sql_server ? "Server=tcp:${azurerm_mssql_server.main[0].fully_qualified_domain_name},1433;Initial Catalog=${local.effective_db_name};User ID=sqladmin;Password=${var.sql_admin_password};Encrypt=true;TrustServerCertificate=false;" :
    local.create_postgresql ? "Host=${azurerm_postgresql_flexible_server.main[0].fqdn};Port=5432;Database=${local.effective_db_name};Username=pgadmin;Password=${var.sql_admin_password};SSL Mode=Require;" :
    local.create_mysql ? "Server=${azurerm_mysql_flexible_server.main[0].fqdn};Port=3306;Database=${local.effective_db_name};User=mysqladmin;Password=${var.sql_admin_password};SslMode=Required;" :
    ""
  )
}

# ============================================
# RESOURCE GROUP
# ============================================

resource "azurerm_resource_group" "main" {
  name     = "${local.resource_prefix}-rg"
  location = var.location
}

# ============================================
# APP SERVICE PLAN (Dynamic OS: Windows for .NET, Linux for others)
# ============================================

resource "azurerm_service_plan" "main" {
  count               = local.is_backend ? 1 : 0
  name                = "${local.resource_prefix}-plan"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = local.is_dotnet ? "Windows" : "Linux"
  sku_name            = local.sku_name

  depends_on = [azurerm_resource_group.main]
}

# ============================================
# WINDOWS WEB APP (.NET only)
# ============================================

resource "azurerm_windows_web_app" "main" {
  count               = local.is_backend && local.is_dotnet ? 1 : 0
  name                = "${local.resource_prefix}-webapp"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main[0].id

  site_config {
    always_on = local.always_on
    application_stack {
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "ASPNETCORE_ENVIRONMENT" = "Production"
  }

  # Auto-inject connection string when database is created
  dynamic "connection_string" {
    for_each = local.has_database ? [1] : []
    content {
      name  = "DefaultConnection"
      type  = local.create_sql_server ? "SQLAzure" : "Custom"
      value = local.connection_string
    }
  }

  depends_on = [
    azurerm_resource_group.main,
    azurerm_service_plan.main
  ]
}

# ============================================
# LINUX WEB APP (Node.js, Python, Java)
# ============================================

resource "azurerm_linux_web_app" "main" {
  count               = local.is_backend && local.is_linux ? 1 : 0
  name                = "${local.resource_prefix}-webapp"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main[0].id

  site_config {
    always_on = local.always_on
    application_stack {
      node_version   = var.runtime_stack == "node" ? "20-lts" : null
      python_version = var.runtime_stack == "python" ? "3.11" : null
      java_version   = var.runtime_stack == "java" ? "17" : null
      java_server         = var.runtime_stack == "java" ? "JAVA" : null
      java_server_version = var.runtime_stack == "java" ? "17" : null
    }
  }

  app_settings = merge(
    { "WEBSITES_PORT" = var.runtime_stack == "node" ? "3000" : var.runtime_stack == "python" ? "8000" : "" },
    local.has_database ? { "DATABASE_URL" = local.connection_string } : {}
  )

  # Auto-inject connection string when database is created
  dynamic "connection_string" {
    for_each = local.has_database ? [1] : []
    content {
      name  = "DefaultConnection"
      type  = "Custom"
      value = local.connection_string
    }
  }

  depends_on = [
    azurerm_resource_group.main,
    azurerm_service_plan.main
  ]
}

# ============================================
# SQL SERVER (conditional - when database_type = "sqlserver")
# ============================================

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

resource "azurerm_mssql_database" "main" {
  count     = local.create_sql_server ? 1 : 0
  name      = local.effective_db_name
  server_id = azurerm_mssql_server.main[0].id
  sku_name  = "Basic"

  depends_on = [
    azurerm_resource_group.main,
    azurerm_mssql_server.main
  ]
}

resource "azurerm_mssql_firewall_rule" "allow_azure" {
  count            = local.create_sql_server ? 1 : 0
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"

  depends_on = [azurerm_mssql_server.main]
}

# ============================================
# POSTGRESQL FLEXIBLE SERVER (conditional - when database_type = "postgresql")
# ============================================

resource "azurerm_postgresql_flexible_server" "main" {
  count                  = local.create_postgresql ? 1 : 0
  name                   = "${local.resource_prefix}-pgserver"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "15"
  administrator_login    = "pgadmin"
  administrator_password = var.sql_admin_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  zone                   = "1"

  depends_on = [azurerm_resource_group.main]
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  count     = local.create_postgresql ? 1 : 0
  name      = local.effective_db_name
  server_id = azurerm_postgresql_flexible_server.main[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [azurerm_postgresql_flexible_server.main]
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  count            = local.create_postgresql ? 1 : 0
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"

  depends_on = [azurerm_postgresql_flexible_server.main]
}

# ============================================
# MYSQL FLEXIBLE SERVER (conditional - when database_type = "mysql")
# ============================================

resource "azurerm_mysql_flexible_server" "main" {
  count                  = local.create_mysql ? 1 : 0
  name                   = "${local.resource_prefix}-mysqlserver"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  administrator_login    = "mysqladmin"
  administrator_password = var.sql_admin_password
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  zone                   = "1"

  depends_on = [azurerm_resource_group.main]
}

resource "azurerm_mysql_flexible_database" "main" {
  count               = local.create_mysql ? 1 : 0
  name                = local.effective_db_name
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.main[0].name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"

  depends_on = [azurerm_mysql_flexible_server.main]
}

resource "azurerm_mysql_flexible_server_firewall_rule" "allow_azure" {
  count               = local.create_mysql ? 1 : 0
  name                = "AllowAzureServices"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.main[0].name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"

  depends_on = [azurerm_mysql_flexible_server.main]
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

output "runtime_stack" {
  value = var.runtime_stack
}

# Backend Web App outputs (works for both Windows and Linux)
output "webapp_name" {
  value = local.is_backend ? (
    local.is_dotnet
      ? (length(azurerm_windows_web_app.main) > 0 ? azurerm_windows_web_app.main[0].name : "")
      : (length(azurerm_linux_web_app.main) > 0 ? azurerm_linux_web_app.main[0].name : "")
  ) : ""
}

output "webapp_url" {
  value = local.is_backend ? (
    local.is_dotnet
      ? (length(azurerm_windows_web_app.main) > 0 ? "https://${azurerm_windows_web_app.main[0].default_hostname}" : "")
      : (length(azurerm_linux_web_app.main) > 0 ? "https://${azurerm_linux_web_app.main[0].default_hostname}" : "")
  ) : ""
}

# Database outputs
output "database_type" {
  value = var.database_type
}

output "db_server_fqdn" {
  value = (
    local.create_sql_server ? azurerm_mssql_server.main[0].fully_qualified_domain_name :
    local.create_postgresql ? azurerm_postgresql_flexible_server.main[0].fqdn :
    local.create_mysql ? azurerm_mysql_flexible_server.main[0].fqdn :
    ""
  )
  sensitive = true
}

output "db_name" {
  value     = local.has_database ? local.effective_db_name : ""
  sensitive = true
}
