# Render the production Butane template + the rig overlay to Ignition JSON.
# Same toolchain as production (terraform templatefile + poseidon/ct) — byte-identical
# semantics. Driven by node/bin/ignite.sh; runs offline via a filesystem provider mirror.
variable "template_path" { type = string }
variable "vars_json"     { type = string } # JSON object of template variables
variable "overlay_butane" { type = string } # rig overlay, Butane YAML

data "ct_config" "prod" {
  content = templatefile(var.template_path, jsondecode(var.vars_json))
  strict  = true
}

data "ct_config" "overlay" {
  content = var.overlay_butane
  strict  = true
}

output "prod_ignition"    { value = data.ct_config.prod.rendered }
output "overlay_ignition" { value = data.ct_config.overlay.rendered }
