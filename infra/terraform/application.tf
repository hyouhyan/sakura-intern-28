//apprun 専有型アプリケーション
resource "sakura_apprun_dedicated_application" "backend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelBackend"

  # NOTE: application を新規作成する apply では null にする必要がある。
  # 詳細は variables.tf の backend_active_version を参照。
  active_version = var.backend_active_version
}

resource "sakura_apprun_dedicated_application" "frontend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelFrontend"

  active_version = var.frontend_active_version
}


########################################
# 公開 URL (TLS 終端)
########################################
#
# TLS 終端は AppRun のロードバランサが行う (nginx などのサイドカーは挟まない)。
# LB は Host ヘッダによる L7 ルーティングをするので、host が異なれば
# 複数のアプリケーションで同じ lb_port (443) を共有できる。
#
#   Browser ──https──> LB :443 ──http──> frontend コンテナ :3000
#            (Host: frontend_host)
#   Browser ──https──> LB :443 ──http──> backend コンテナ :8080
#            (Host: backend_host)
#
# ブラウザは frontend と backend の両方に別オリジンでアクセスするため
# (app/backend/internal/handler/handler.go の CookieSecure のコメントを参照)、
# 双方を HTTPS にしないとセッション Cookie (Secure + SameSite=None) が載らない。

locals {
  # TLS を切っているときは、ワーカーノードのグローバル IP に
  # 平文で直接ぶら下がる従来の形にフォールバックする。
  frontend_url = var.enable_tls ? "https://${var.frontend_host}" : "http://${sakura_internet.main.min_ip_address}:3000"
  backend_url  = var.enable_tls ? "https://${var.backend_host}" : "http://${sakura_internet.main.min_ip_address}:8080"
}


//app run
resource "sakura_apprun_dedicated_version" "backend" {
  # LB が出来てから version を作る (lb_port の接続先を確定させるため)
  depends_on = [sakura_database.db, sakura_apprun_dedicated_lb.main]

  application_id           = sakura_apprun_dedicated_application.backend.id
  cpu                      = 1000
  memory                   = 512
  image                    = "${sakura_container_registry.intern.fqdn}/${var.sakuravel_backend_image_name}"
  registry_username        = var.registry_apprun_user_name
  registry_password        = var.registry_apprun_user_password
  registry_password_action = "new"
  scaling_mode             = "manual"
  fixed_scale              = 1

  # lb_port 80 のエントリは不要。Let's Encrypt の HTTP-01 チャレンジに
  # 必要なのは「クラスタに 80/http ポートが存在すること」であって
  # (cluster.tf 参照)、アプリ側で 80 番を受ける必要はない。
  # 80 番を張らないので、平文でのアクセス経路自体が存在しない。
  #
  # exposed_ports は nested attribute なので、リスト全体を local などの式で
  # 組み立てると target_port の必須チェックに引っかかる。
  # そのため TLS の分岐は属性ごとの三項演算子で書いている。
  exposed_ports = [{
    target_port      = 8080
    lb_port          = var.enable_tls ? 443 : null
    host             = var.enable_tls ? [var.backend_host] : null
    use_lets_encrypt = var.enable_tls ? true : null
  }]

  env_vars = [{
    key    = "DATABASE_URL"
    value  = "${var.db_username}:${var.db_password}@tcp(${element(split("/", var.db_private_net_cidr), 0)}:3306)/${var.db_name}?parseTime=true&charset=utf8mb4"
    secret = true
    }, {
    key    = "PORT"
    value  = "8080"
    secret = false
    }, {
    # CORS の許可オリジン。ブラウザが載せてくる Origin と完全一致する必要がある
    # (cmd/api/main.go の corsMiddleware)。
    key    = "ALLOWED_ORIGIN"
    value  = local.frontend_url
    secret = false
    }, {
    # HTTPS のときだけ Secure + SameSite=None を付ける。
    # 別オリジン間で Cookie を送るには SameSite=None が必須で、
    # SameSite=None は Secure とセットでないとブラウザに拒否される。
    key    = "COOKIE_SECURE"
    value  = var.enable_tls ? "true" : "false"
    secret = false
  }]
}

resource "sakura_apprun_dedicated_version" "frontend" {
  depends_on = [sakura_apprun_dedicated_lb.main]

  application_id           = sakura_apprun_dedicated_application.frontend.id
  cpu                      = 1000
  memory                   = 512
  image                    = "${sakura_container_registry.intern.fqdn}/intern2026-app-frontend:latest"
  registry_username        = var.registry_apprun_user_name
  registry_password        = var.registry_apprun_user_password
  registry_password_action = "new"
  scaling_mode             = "manual"
  fixed_scale              = 1

  exposed_ports = [{
    target_port      = 3000
    lb_port          = var.enable_tls ? 443 : null
    host             = var.enable_tls ? [var.frontend_host] : null
    use_lets_encrypt = var.enable_tls ? true : null
  }]

  env_vars = [{
    key    = "API_URL"
    value  = local.backend_url
    secret = false
  }]
}
