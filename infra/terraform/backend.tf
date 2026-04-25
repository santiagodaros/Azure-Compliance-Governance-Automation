# Remote state stored in Azure Blob Storage with lease-based locking.
# Initialize with: terraform init -backend-config=backend-<env>.tfbackend
terraform {
  backend "azurerm" {
    container_name = "tfstate"
    key            = "core.terraform.tfstate"
    use_oidc       = true
  }
}
