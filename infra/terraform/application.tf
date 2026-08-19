//apprun 専有型アプリケーション
resource "sakura_apprun_dedicated_application" "backend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelBackend"
}

resource "sakura_apprun_dedicated_application" "frontend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelFrontend"
}



//app run
resource "sakura_apprun_dedicated_version" "backend" {
  depends_on = [sakura_database.db]

  application_id           = sakura_apprun_dedicated_application.backend.id
  cpu                      = 1000
  memory                   = 512
  image                    = "${sakura_container_registry.intern.fqdn}/${var.sakuravel_backend_image_name}"
  registry_username        = var.registry_apprun_user_name
  registry_password        = var.registry_apprun_user_password
  registry_password_action = "new"
  scaling_mode             = "manual"
  fixed_scale              = 1
  exposed_ports = [{
    target_port = 8080
    lb_port     = null
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
    key    = "ALLOWED_ORIGIN"
    value  = "http://${sakura_internet.main.min_ip_address}:3000"
    secret = false
    }, {
    key    = "COOKIE_SECURE"
    value  = "false"
    secret = false
  }]
}

resource "sakura_apprun_dedicated_version" "frontend" {
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
    target_port = 3000
    lb_port     = null
  }]
  env_vars = [{
    key    = "API_URL"
    value  = "http://${sakura_internet.main.min_ip_address}:8080"
    secret = false
  }]
}
