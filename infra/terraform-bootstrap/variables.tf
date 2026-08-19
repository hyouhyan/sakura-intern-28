########################################
# 認証
########################################

variable "sakura_access_token" {
  description = "さくらのクラウド API アクセストークン。環境変数 SAKURA_ACCESS_TOKEN でも供給可。"
  type        = string
  default     = null
  sensitive   = true
}

variable "sakura_access_token_secret" {
  description = "さくらのクラウド API アクセストークンシークレット。環境変数 SAKURA_ACCESS_TOKEN_SECRET でも供給可。"
  type        = string
  default     = null
  sensitive   = true
}

########################################
# オブジェクトストレージ (Terraform state 保存用)
########################################

variable "object_storage_site_id" {
  description = "オブジェクトストレージのサイト ID。石狩 = \"isk01\" / 東京 = \"tky01\"。"
  type        = string
  default     = "isk01"
}

variable "bucket_name" {
  description = "Terraform state 保存用バケット名。"
  type        = string
  default     = "intern26-group-d-bucket"
}
