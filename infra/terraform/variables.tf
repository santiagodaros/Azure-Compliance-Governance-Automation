variable "environment" {
  type        = string
  description = "Deployment environment (dev | prod)."
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "location" {
  type        = string
  description = "Primary Azure region for all resources."
  default     = "eastus2"
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID."
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant ID."
}

variable "sql_admin_login" {
  type        = string
  description = "SQL Server local administrator login."
  default     = "coreadmin"
}

variable "sql_admin_password" {
  type        = string
  description = "SQL Server local administrator password. Sourced from TF_VAR_sql_admin_password."
  sensitive   = true
}

variable "entra_admin_login" {
  type        = string
  description = "Entra ID display name for the SQL Entra admin (typically the Managed Identity name)."
}

variable "enable_private_networking" {
  type        = bool
  description = "Deploy VNet and private endpoints."
  default     = false
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the optional VNet."
  default     = ["10.0.0.0/16"]
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto all resources."
  default     = {}
}
