terraform {
  required_version = ">= 1.5"
  required_providers {
    ct = {
      source  = "poseidon/ct"
      version = "0.13.0" # same pin as providers/vsphere/cicd/terraform/providers.tf
    }
  }
}
