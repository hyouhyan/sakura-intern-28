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
  default     = "is1a" # 石狩第1ゾーン。tk1a / tk1b / is1a / is1b / is1c から選択
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
  default     = "sakuravel-is1a"

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
# nginx アプリケーション
########################################

variable "nginx_app_name" {
  description = "nginx アプリケーションの名前 (英数字とハイフン・アンダースコアのみ)"
  type        = string
  default     = "nginx-demo"
}

variable "nginx_replicas" {
  description = <<-EOT
    起動する nginx コンテナの数。LB はこの台数に振り分ける。
    AppRun はコンテナ 1 個につきワーカーノード 1 台を割り当てるため、
    この値は asg_max_nodes 以下である必要がある。
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.nginx_replicas <= var.asg_max_nodes
    error_message = "nginx_replicas は asg_max_nodes 以下にしてください。AppRun はコンテナ 1 個につきワーカーノード 1 台を割り当てます。"
  }
}

variable "nginx_image" {
  description = <<-EOT
    nginx のコンテナイメージ。
    AppRun 専有型は非 root でコンテナを実行するため、root 前提の
    nginx:latest や nginxdemos/hello は port 80 に bind できず起動に失敗する。
    非 root 向けにビルドされた nginx-unprivileged を使うこと。
  EOT
  type        = string
  default     = "nginxinc/nginx-unprivileged:stable-alpine"
}

variable "nginx_container_port" {
  description = <<-EOT
    コンテナが listen するポート。
    AppRun 専有型のコンテナは非 root 実行なので特権ポート (80 番) には
    bind できない。8080 などの非特権ポートを使うこと。
  EOT
  type        = number
  default     = 8080
}

variable "nginx_tls_container_port" {
  description = <<-EOT
    HTTPS (lb_port 443) の転送先となるコンテナのポート。

    AppRun は exposed_ports 間で target_port が重複するとエラーになるため
    (400 "Target port is duplicated")、HTTP 用とは別のポートにする必要がある。
    nginx 側は同一 server ブロックで両方を listen する。
  EOT
  type        = number
  default     = 8081

  validation {
    condition     = var.nginx_tls_container_port != var.nginx_container_port
    error_message = "nginx_tls_container_port は nginx_container_port と別の値にしてください。AppRun は target_port の重複を許しません。"
  }
}

variable "nginx_active_version" {
  description = <<-EOT
    有効化する nginx アプリのバージョン番号。

    provider の application リソースは Create 時に active_version を送らず、
    API が返す null で state を上書きする。そのため application を新規作成する
    apply でこの値を指定すると "Provider produced inconsistent result after
    apply" で失敗する。有効化は Update 経由でしか行えない。

    したがって以下の場合は 2 段階で apply する:
      - application を新規作成するとき
      - version を作り直すとき (アクティブな version は削除できない)

      1 回目: terraform apply -var-file=deactivate.tfvars
      2 回目: terraform apply -var 'nginx_active_version=<terraform output nginx_version の値>'

    -var では null を渡せない (文字列 "null" になり number に変換できず失敗する) ため、
    無効化には deactivate.tfvars を使う。
    構成を変えない通常時は default のままで apply すればよい。
  EOT
  type        = number
  default     = 1
}

variable "nginx_hosts" {
  description = <<-EOT
    LB が nginx に振り分ける Host ヘッダの値 (FQDN)。
    HTTP (80) では、ここで指定した FQDN に加えて LB の VIP も常に受け付ける
    ため、IP 直打ちでの動作確認も引き続き可能。
    nginx_enable_tls を有効にする場合は必ず指定すること。
    DNS の A レコード (FQDN -> LB の VIP) は手動で登録する前提。
  EOT
  type        = list(string)
  default     = null
}

variable "nginx_enable_tls" {
  description = <<-EOT
    Let's Encrypt による TLS 終端 (lb_port 443) を有効にする。

    前提:
      - nginx_hosts に FQDN を指定していること
        (LE は IP アドレスに証明書を発行できない)
      - その FQDN の A レコードが LB の VIP を指していること
      - CDN のプロキシを経由していないこと
        (LE の HTTP-01 チャレンジが 80 番に到達する必要がある)
      - cluster.tf の ports に 80/http と 443/https があること
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.nginx_enable_tls || try(length(var.nginx_hosts) > 0, false)
    error_message = "nginx_enable_tls を有効にする場合は nginx_hosts に FQDN を指定してください。Let's Encrypt は IP アドレスに証明書を発行できません。"
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
  description = "オートスケーリンググループの最大ノード数。nginx_replicas 以上にする"
  type        = number
  default     = 3
}
