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
  # 石狩第3ゾーン。tk1a / tk1b / is1a / is1b / is1c から選択。
  # is1a はゾーン内のスイッチ数上限に引っかかり、この構成が必要とする
  # 2 つ (ルータ付属 + プライベート) を確保できなかったため is1c にしている。
  default = "is1c"
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
  description = "作成するクラスタの名前 (20文字以内)"
  type        = string
  default     = "sakuravel-is1c"

  validation {
    condition     = length(var.cluster_name) <= 20
    error_message = "クラスタ名は20文字以内にしてください。"
  }
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

variable "db_port" {
  description = <<-EOT
    データベースアプライアンスが待ち受けるポート。
    database.tf の network_interface.port と、アプリコンテナに渡す
    DB_PORT の両方に使う。

    network_interface.port を省略すると、database_type に関係なく
    API 側の既定値 5432 (PostgreSQL のポート) が入る。MariaDB でも
    5432 で待ち受けてしまい、3306 宛の接続は届かない。
    そのため database.tf では必ず明示している。
  EOT
  type        = number
  default     = 3306

  validation {
    condition     = var.db_port >= 1024 && var.db_port <= 65535
    error_message = "db_port は 1024-65535 の範囲にしてください (アプライアンスの制約)。"
  }
}

########################################
# プライベートネットワーク (vSwitch)
########################################

variable "private_net_cidr" {
  description = <<-EOT
    アプリケーションコンテナ (AppRun のワーカーノード) と DB アプライアンスを
    つなぐプライベートネットワークのセグメント。

    ネットワークアドレスで指定すること (ホストアドレスを含む
    db_private_net_cidr とは書式が異なる)。
    db_private_net_cidr / db_private_net_allow_cidr と同じセグメントにすること。
  EOT
  type        = string
  default     = "192.168.1.0/24"
}

variable "app_private_ip_offset" {
  description = <<-EOT
    ワーカーノードのプライベート側 IP を、セグメントの先頭から何番目の
    アドレスから払い出すか。ここから asg_max_nodes 個ぶんを ASG の
    IP プールに割り当てる。

    既定の 192.168.1.0/24 では .100 から asg_max_nodes 個 (既定 3 台なら
    .100 - .102) を使う。DB アプライアンス (既定 .30)、ゲートウェイ
    (既定 .1) と重ならない値にすること。
  EOT
  type        = number
  default     = 100

  validation {
    condition     = var.app_private_ip_offset >= 1
    error_message = "app_private_ip_offset は 1 以上にしてください (0 はネットワークアドレスです)。"
  }
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
# アプリケーションの公開設定 (TLS 終端)
########################################

variable "frontend_host" {
  description = <<-EOT
    フロントエンドを公開する FQDN。LB はこの Host ヘッダを見て
    frontend コンテナ (:3000) に振り分ける。
    ブラウザのオリジンになるので、backend の ALLOWED_ORIGIN にもこの値が入る。
    DNS の A レコード (FQDN -> terraform output -raw lb_vip) は手動で登録する前提。
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "backend_host" {
  description = <<-EOT
    バックエンド API を公開する FQDN。LB はこの Host ヘッダを見て
    backend コンテナ (:8080) に振り分ける。

    frontend_host とは別の FQDN にすること。LB は Host ヘッダでしか
    振り分けられないため、同じ FQDN では 2 つのアプリを出し分けられない。
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "enable_tls" {
  description = <<-EOT
    AppRun のロードバランサによる TLS 終端 (lb_port 443 + Let's Encrypt) を有効にする。

    無効の場合、アプリは LB に接続されず (lb_port = null)、
    ワーカーノードのグローバル IP に平文 HTTP で直接ぶら下がる形になる。

    有効にする前提:
      - frontend_host / backend_host に FQDN を指定していること
        (Let's Encrypt は IP アドレスに証明書を発行できない)
      - どちらの FQDN も A レコードが LB の VIP を指していること
      - CDN のプロキシを経由していないこと
        (LE の HTTP-01 チャレンジが 80 番に到達する必要がある)
      - cluster.tf の ports に 80/http と 443/https があること
        (LB のポートはクラスタ作成時にしか設定できず、後から追加できない)
  EOT
  type        = bool

  validation {
    condition     = !var.enable_tls || (try(length(var.frontend_host) > 0, false) && try(length(var.backend_host) > 0, false))
    error_message = "enable_tls を有効にする場合は frontend_host と backend_host の両方に FQDN を指定してください。Let's Encrypt は IP アドレスに証明書を発行できません。"
  }

  validation {
    condition     = !var.enable_tls || var.frontend_host != var.backend_host
    error_message = "frontend_host と backend_host には別の FQDN を指定してください。LB は Host ヘッダでしか振り分けられません。"
  }
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
  description = <<-EOT
    オートスケーリンググループの最大ノード数。

    NOTE: 「コンテナ 1 個につきワーカーノード 1 台」ではない。
    ノードの空きリソースに収まる限り、AppRun は 1 台のノードに複数の
    コンテナを載せる。実測では backend 3 + frontend 1 = 4 コンテナ
    (いずれも cpu=1000 / memory=512) が 3 ノードに収まった。
    したがってこの値はノード数の上限であって、コンテナ数の上限ではない。

    NOTE: min_nodes / max_nodes は RequiresReplace で、provider は ASG の
    Update を実装していない。この値を変えるだけで ASG が作り直しになり、
    ASG を参照している LB も巻き添えで再作成される
    (実測で 20 分前後のダウン + Let's Encrypt 証明書の再発行)。
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.asg_max_nodes >= var.asg_min_nodes
    error_message = "asg_max_nodes は asg_min_nodes 以上にしてください。"
  }
}

variable "backend_replicas" {
  description = <<-EOT
    起動する backend コンテナの数。LB はこの台数に振り分ける。

    ノード数との関係は asg_max_nodes の説明を参照。
    ノードの空きリソース次第で 1 ノードに複数コンテナが載るため、
    レプリカ数と同じだけのノードが必要になるとは限らない。
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.backend_replicas >= 1
    error_message = "backend_replicas は 1 以上にしてください。"
  }
}

variable "frontend_replicas" {
  description = "起動する frontend コンテナの数。"
  type        = number
  default     = 1
}

########################################
# コンテナレジストリ
########################################


variable "registry_name" {
  description = "コンテナレジストリの表示名"
  type        = string
  default     = "intern131313"
}

variable "registry_subdomain_label" {
  description = <<-EOT
    コンテナレジストリのホスト名になるラベル (<label>.sakuracr.jp)。

    sakuracr.jp 全体で一意なので、他アカウントで使われている名前は作成できず
    "registry_name: すでに利用されています" で 400 になる。
    既存のレジストリを使う場合は、そのラベルを指定して terraform import すること。
  EOT
  type        = string
  default     = "intern131313"
}

variable "registry_ci_user_password" {
  description = "GitHub Actions push用アカウントのパスワード"
  type        = string
  sensitive   = true
}

variable "registry_apprun_user_password" {
  description = "AppRun pull用アカウントのパスワード"
  type        = string
  sensitive   = true
}

variable "registry_apprun_user_name" {
  description = "AppRun pull用アカウント名"
  type        = string
  default     = "apprun"
}

variable "sakuravel_backend_image_name" {
  description = "デプロイするBackendイメージ名。TF_VAR_sakuravel_backend_image_nameで指定し、Frontendも同じtagを使用する。"
  type        = string
}
