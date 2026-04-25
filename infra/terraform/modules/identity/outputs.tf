output "app_client_id" {
  description = "App Registration client ID (VITE_AZURE_CLIENT_ID / CORE_CLIENT_ID)."
  value       = azuread_application.core.client_id
}

output "app_object_id" {
  description = "App Registration object ID."
  value       = azuread_application.core.object_id
}

output "service_principal_id" {
  description = "Service Principal object ID."
  value       = azuread_service_principal.core.object_id
}

output "api_principal_id" {
  description = "Alias — same as service_principal_id for RBAC wiring in root module."
  value       = azuread_service_principal.core.object_id
}
