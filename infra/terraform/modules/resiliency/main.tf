resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# ── Recovery Services Vault ───────────────────────────────────────────────────

resource "azurerm_recovery_services_vault" "this" {
  name                = "rsv-core-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  soft_delete_enabled = true
  immutability        = "Unlocked"
  tags                = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# ── Automation Account ────────────────────────────────────────────────────────

resource "azurerm_automation_account" "this" {
  name                = "aa-core-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Basic"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ── ASR Test Failover Runbook ─────────────────────────────────────────────────

resource "azurerm_automation_runbook" "tfo" {
  name                    = "Runbook-ASR-TFO"
  resource_group_name     = var.resource_group_name
  location                = var.location
  automation_account_name = azurerm_automation_account.this.name
  log_verbose             = false
  log_progress            = true
  description             = "ASR Test Failover orchestration runbook for CORE."
  runbook_type            = "PowerShell"
  content                 = var.runbook_content
  tags                    = var.tags
}

# ── Logic App with HTTP trigger ───────────────────────────────────────────────

resource "azurerm_logic_app_workflow" "this" {
  name                = "la-core-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_logic_app_trigger_http_request" "webhook" {
  name         = "webhook-trigger"
  logic_app_id = azurerm_logic_app_workflow.this.id

  schema = jsonencode({
    type = "object"
    properties = {
      resourceId = { type = "string" }
      eventType  = { type = "string" }
      severity   = { type = "string" }
      message    = { type = "string" }
    }
  })
}

# ── Blob Storage for compliance reports ──────────────────────────────────────

resource "azurerm_storage_account" "this" {
  name                     = "stcore${var.environment}${random_string.suffix.result}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags
}

resource "azurerm_storage_container" "compliance" {
  name                  = "compliance-reports"
  storage_account_name  = azurerm_storage_account.this.name
  container_access_type = "private"
}
