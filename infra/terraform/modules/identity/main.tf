data "azuread_client_config" "current" {}

# ── App Registration (Entra ID) for CORE frontend auth ───────────────────────

resource "azuread_application" "core" {
  display_name = "CORE-ResiliencyEngine-${var.environment}"
  owners       = [data.azuread_client_config.current.object_id]

  web {
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = true
    }
  }

  single_page_application {
    redirect_uris = [
      "http://localhost:5173/",
      "http://localhost:4173/",
    ]
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "core" {
  client_id                    = azuread_application.core.client_id
  app_role_assignment_required = false
  owners                       = [data.azuread_client_config.current.object_id]
}

# App roles for RBAC (L1 Support and DR Admin)
resource "azuread_application_app_role" "l1_support" {
  application_id = azuread_application.core.id
  allowed_member_types = ["User"]
  description          = "Read-only access — view dashboards and export reports."
  display_name         = "L1 Support"
  enabled              = true
  id                   = "10000000-0000-0000-0000-000000000001"
  value                = "L1.Support"
}

resource "azuread_application_app_role" "dr_admin" {
  application_id = azuread_application.core.id
  allowed_member_types = ["User"]
  description          = "Full access — execute drills and manage resiliency settings."
  display_name         = "Disaster Recovery Admin"
  enabled              = true
  id                   = "10000000-0000-0000-0000-000000000002"
  value                = "DR.Admin"
}
