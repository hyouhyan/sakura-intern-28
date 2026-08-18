########################################
# サーバー
########################################

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

//zone定義
data "sakura_zone" "tk1a" {
  name = "tk1a"
}

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

  ports = [
    {
      port     = 80
      protocol = "http"
    },
  ]
}


//apprun占有型
resource "sakura_apprun_dedicated_application" "main" {
  cluster_id = sakura_apprun_dedicated_cluster.main.id
  name       = "SakuravelApp"
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
  zone                      = data.sakura_zone.tk1a.name
  worker_service_class_path = data.sakura_apprun_dedicated_worker_service_classes.main.classes[0].path
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
  }]
}

//app run 占有型version
resource "sakura_apprun_dedicated_version" "main" {
  application_id = sakura_apprun_dedicated_application.main.id
  cpu            = 1000
  memory         = 512
  image          = "nginx:latest"
  cmd            = ["/bin/sh"]
  scaling_mode   = "manual"
  fixed_scale    = 1
}

