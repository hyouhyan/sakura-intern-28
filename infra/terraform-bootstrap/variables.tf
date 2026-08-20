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
}

########################################
# コンテナレジストリ
########################################
# infra/terraform (CI からのみ apply) 側に置くと、docker login が
# レジストリの存在を前提にしているせいで「レジストリが無いと作れず、
# 作らないとログインできない」循環に陥る。bootstrap はローカルからの
# 手動一度きりの apply で docker login を経由しないため、ここに置く。

variable "registry_name" {
  description = "コンテナレジストリの表示名"
  type        = string
}

variable "registry_subdomain_label" {
  description = <<-EOT
    コンテナレジストリのホスト名になるラベル (<label>.sakuracr.jp)。

    sakuracr.jp 全体で一意なので、他アカウントで使われている名前は作成できず
    "registry_name: すでに利用されています" で 400 になる。
    既存のレジストリを使う場合は、そのラベルを指定して terraform import すること。
  EOT
  type        = string
}

variable "registry_ci_user_password" {
  description = "GitHub Actions push用アカウントのパスワード"
  type        = string
  sensitive   = true
}

variable "registry_apprun_user_name" {
  description = "AppRun pull用アカウント名"
  type        = string
  default     = "apprun"
}

variable "registry_apprun_user_password" {
  description = "AppRun pull用アカウントのパスワード"
  type        = string
  sensitive   = true
}

########################################
# 初期イメージ投入 (配布元レジストリからのシード)
########################################

variable "source_registry_host" {
  description = "配布元コンテナレジストリのホスト名。ここから frontend/backend の初期イメージを取得する。"
  type        = string
  default     = "intern22.sakuracr.jp"
}

variable "source_registry_username" {
  description = "配布元コンテナレジストリのログインユーザー名。"
  type        = string
  sensitive   = true
}

variable "source_registry_password" {
  description = "配布元コンテナレジストリのログインパスワード。"
  type        = string
  sensitive   = true
}

variable "seed_images" {
  description = <<-EOT
    bootstrap時に配布元レジストリ (source_registry_host) から取得し、
    自分たちのレジストリへ push しておくイメージ名の一覧 (タグは常に latest)。
  EOT
  type        = list(string)
  default     = ["intern2026-app-frontend", "intern2026-app-backend"]
}
