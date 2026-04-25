environment = "prod"
location    = "eastus2"

# Replace with your actual IDs — never commit real secrets here.
# Sensitive values (sql_admin_password) must be set via TF_VAR_* env vars.
subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"

sql_admin_login   = "coreadmin"
entra_admin_login = "id-core-api-prod"

enable_private_networking = true

tags = {
  cost_center = "engineering"
  team        = "platform"
}
