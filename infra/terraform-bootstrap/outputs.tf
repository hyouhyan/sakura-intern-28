# このモジュールはバケット自体を作成するため、ローカルで一度だけ手動 apply する
# (state もローカル管理。infra/.gitignore の *.tfstate で除外済み)。
# apply 後、以下の値を GitHub Secrets (TFSTATE_ACCESS_KEY_ID / TFSTATE_SECRET_ACCESS_KEY)
# に登録し、infra/terraform 側の S3 backend 認証に使用する。

output "bucket_name" {
  description = "Terraform state 保存用バケット名。terraform init 時の TFSTATE_BUCKET に設定する。"
  value       = sakura_object_storage_bucket.tfstate.name
}

output "access_key" {
  description = "オブジェクトストレージ用アクセスキー。GitHub Secrets の TFSTATE_ACCESS_KEY_ID に登録する。"
  value       = sakura_object_storage_permission.tfstate.access_key
  sensitive   = true
}

output "secret_key" {
  description = "オブジェクトストレージ用シークレットキー。GitHub Secrets の TFSTATE_SECRET_ACCESS_KEY に登録する。"
  value       = sakura_object_storage_permission.tfstate.secret_key
  sensitive   = true
}

output "registry_fqdn" {
  description = "コンテナレジストリの FQDN。infra/terraform 側の data source から参照される。"
  value       = sakura_container_registry.intern.fqdn
}

output "registry_subdomain_label" {
  description = "コンテナレジストリのサブドメインラベル。GitHub Secrets の REGISTRY_SUBDOMAIN と一致させる。"
  value       = sakura_container_registry.intern.subdomain_label
}
