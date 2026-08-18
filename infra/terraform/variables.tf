########################################
# 認証・ゾーン
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

variable "zone" {
  description = "リソースを作成するゾーン。"
  type        = string
  default     = "tk1a" # 石狩第2ゾーン。tk1a / tk1b / is1a / is1b / is1c から選択
}

########################################
# サーバー
########################################

variable "server_name" {
  description = "作成するサーバーの名前"
  type        = string
  default     = "docker-host"
}

variable "server_private_net_cidr" {
  description = "サーバーが接続するプライベートネットワークの CIDR"
  type        = string
  default     = "192.168.1.40/24"
}

variable "server_password" {
  description = "サーバーの初期パスワード (SSH 公開鍵認証を使用する場合でも必要)"
  type        = string
  sensitive   = true
}

variable "server_ssh_public_key_path" {
  description = "サーバーへの SSH 公開鍵認証で使用する公開鍵ファイルのパス"
  type        = string
  default     = ""
}

########################################
# クラスタ
########################################

variable "cluster_name" {
  description = "作成するクラスタの名前"
  type        = string
  default     = "sakuravel-cluster"
}

variable "cluster_lets_encrypt_email" {
  description = "クラスタの Let's Encrypt 証明書を取得する際に使用するメールアドレス"
  type        = string
  default     = "hyouhyan@hyouhyan.com"
}

variable "service_principal_id" {
  description = "クラスタのサービスプリンシパル ID"
  type        = string
  default     = ""
}

########################################
# データベースアプライアンス
########################################

variable "db_username" {
  description = "データベースのユーザー名"
  type        = string
  default     = "sakuravel_app"
}

variable "db_password" {
  description = "データベースのパスワード"
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "作成するデータベース名"
  type        = string
  default     = "sakuravel_app"
}

variable "db_private_net_cidr" {
  description = "データベースアプライアンスが接続するプライベートネットワークの CIDR"
  type        = string
  default     = "192.168.1.30/24"
}

variable "db_private_net_gateway" {
  description = "データベースアプライアンスが使用するプライベートネットワークのデフォルトゲートウェイ"
  type        = string
  default     = "192.168.1.1"
}

variable "db_private_net_allow_cidr" {
  description = "データベースアプライアンスへのアクセスを許可するネットワークアドレスの CIDR"
  type        = string
  default     = "192.168.1.0/24"
}

########################################
# ロードバランサ
########################################

variable "lb_name" {
  description = "AppRun 専有型ロードバランサの名前"
  type        = string
  default     = "SakuravelLB"
}

########################################
# ワーカーノード数
########################################

variable "asg_min_nodes" {
  description = "オートスケーリンググループの最小ノード数"
  type        = number
  default     = 1
}

variable "asg_max_nodes" {
  description = "オートスケーリンググループの最大ノード数。nginx_replicas 以上にする"
  type        = number
  default     = 1
}
