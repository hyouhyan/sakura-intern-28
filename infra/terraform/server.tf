########################################
# サーバー #######################################

# data "sakura_archive" "ubuntu" {
#   name = "Ubuntu Server 24.04.2 LTS 64bit (cloudimg)"
#   zone = var.zone
# }
#
# resource "sakura_disk" "docker_host" {
#   name              = "${var.server_name}-disk"
#   plan              = "ssd"
#   size              = 20
#   source_archive_id = data.sakura_archive.ubuntu.id
# }

# resource "sakura_server" "docker_host" {
#   name   = var.server_name
#   disks  = [sakura_disk.docker_host.id]
#   core   = 1
#   memory = 1
#
#   # 共有セグメント接続
#   network_interface = [
#     { upstream = "shared" },
#     { upstream = sakura_vswitch.private_net.id },
#   ]
#
#   # cloud-init user-data
#   user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
#     hostname        = var.server_name
#     password        = var.server_password
#     ssh_public_key  = var.server_ssh_public_key_path != "" ? file(pathexpand(var.server_ssh_public_key_path)) : ""
#     private_ip_cidr = var.server_private_net_cidr
#   })
# }

# output "server_ip_address" {
#   value = sakura_server.docker_host.ip_address
# }


# resource "sakura_iam_project" "foobar" {
#   name        = "foobar"
#   code        = "foobar-code"
#   description = "description"
# }
#
# resource "sakura_iam_service_principal" "sp" {
#   name        = "SakuravelSP"
#   description = "description"
#   project_id  = sakura_iam_project.foobar.id
# }
#
# data "sakura_iam_service_principal" "main" {
#   name = "SakuravelSAP"
# }

//apprun 占有クラスタ
resource "sakura_apprun_dedicated_cluster" "main" {
  name                 = "SakuravelCluster"
  service_principal_id = "113801849783"
  # lets_encrypt_email   = "tf-test-email@sakura.ad.jp"
}


//apprun占有型
resource "sakura_apprun_dedicated_application" "backend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelBackend"
}

resource "sakura_apprun_dedicated_application" "frontend" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelFrontend"
}

resource "sakura_internet" "main" {
  name = "SarkuravelInternet"

  netmask     = 28
  band_width  = 100
  enable_ipv6 = false

  description = "description"
  tags        = ["tag1", "tag2"]
}
data "sakura_apprun_dedicated_worker_service_classes" "main" {}

//オートスケーリンググループ
resource "sakura_apprun_dedicated_auto_scaling_group" "main" {
  cluster_id                = sakura_apprun_dedicated_cluster.main.id
  name                      = "SakuravelASG"
  zone                      = var.zone
  worker_service_class_path = data.sakura_apprun_dedicated_worker_service_classes.main.classes[3].path
  # name_servers              = local.sakura_dns
  min_nodes = 1
  max_nodes = 1

  interfaces = [{
    interface_index = 0
    upstream        = sakura_internet.main.vswitch_id
    connects_to_lb  = false
    netmask         = sakura_internet.main.netmask
    default_gateway = sakura_internet.main.gateway
    ip_pool = [{
      start = sakura_internet.main.min_ip_address
      end   = sakura_internet.main.max_ip_address
    }]
    }, {
    interface_index = 1
    upstream        = sakura_vswitch.private_net.id
    connects_to_lb  = false
    netmask         = tonumber(element(split("/", var.server_private_net_cidr), 1))
    ip_pool = [{
      start = element(split("/", var.server_private_net_cidr), 0)
      end   = element(split("/", var.server_private_net_cidr), 0)
    }]
  }]
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
