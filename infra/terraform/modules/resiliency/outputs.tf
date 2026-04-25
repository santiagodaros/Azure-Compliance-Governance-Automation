output "vault_id" {
  description = "Recovery Services Vault resource ID."
  value       = azurerm_recovery_services_vault.this.id
}

output "vault_name" {
  description = "Recovery Services Vault name."
  value       = azurerm_recovery_services_vault.this.name
}

output "automation_account_id" {
  description = "Automation Account resource ID."
  value       = azurerm_automation_account.this.id
}

output "automation_account_name" {
  description = "Automation Account name."
  value       = azurerm_automation_account.this.name
}

output "logic_app_id" {
  description = "Logic App resource ID."
  value       = azurerm_logic_app_workflow.this.id
}

output "logic_app_callback_url" {
  description = "HTTP trigger callback URL for the Logic App webhook."
  value       = azurerm_logic_app_trigger_http_request.webhook.callback_url
  sensitive   = true
}

output "storage_account_id" {
  description = "Blob Storage account resource ID."
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  description = "Blob Storage account name."
  value       = azurerm_storage_account.this.name
}
