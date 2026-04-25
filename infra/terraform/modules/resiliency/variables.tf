variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "environment" {
  type = string
}

variable "runbook_content" {
  type        = string
  description = "Raw PowerShell content of Runbook-ASR-TFO."
}

variable "tags" {
  type    = map(string)
  default = {}
}
