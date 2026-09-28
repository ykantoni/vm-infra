output "namespace" {
  value = var.namespace
}

output "apps_namespace" {
  value = var.apps_namespace
}

output "sealed_secrets_key_restored" {
  description = "Whether a Sealed Secrets key backup was found and restored. false on a first build: back the generated key up with `just seal-key-backup`."
  value       = local.sealed_secrets_key_present
}
