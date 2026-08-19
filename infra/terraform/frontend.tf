########################################
# フロントエンド
########################################
#
# 今回の作業対象外のアプリ。イメージは配布物をそのまま使う。

resource "sakura_apprun_dedicated_application" "frontend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelFrontend"

  active_version = var.frontend_active_version
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
