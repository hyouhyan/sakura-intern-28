########################################
# バックエンド API (Sakuravel / Go)
########################################

resource "sakura_apprun_dedicated_application" "backend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelBackend"

  # NOTE: 新規作成時は null にする必要がある。詳細は variables.tf の
  # backend_active_version を参照。
  active_version = var.backend_active_version
}

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
  # なお exposed_ports は nested attribute なので、リスト全体を式で組み立てると
  # target_port の必須チェックに引っかかる。属性ごとに三項演算子を使うこと。
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
