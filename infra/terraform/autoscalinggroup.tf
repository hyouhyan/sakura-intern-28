########################################
# オートスケーリンググループ
########################################

locals {
  sakura_dns = ["133.242.0.3", "133.242.0.4"]
}

########################################
# ルータ+スイッチ (グローバル IP を ASG ノードに払い出すため)
########################################
resource "sakura_internet" "main" {
  name       = "SarkuravelInternet"
  zone       = var.zone
  netmask    = 28
  band_width = 100
}

data "sakura_apprun_dedicated_worker_service_classes" "main" {}

resource "sakura_apprun_dedicated_auto_scaling_group" "main" {
  cluster_id                = sakura_apprun_dedicated_cluster.example.id
  name                      = "SakuravelASG"
  zone                      = var.zone
  worker_service_class_path = data.sakura_apprun_dedicated_worker_service_classes.main.classes[0].path
  name_servers              = local.sakura_dns
  min_nodes                 = 1
  max_nodes                 = 3

  interfaces = [{
    interface_index = 0
    upstream        = sakura_internet.main.vswitch_id
    connects_to_lb  = true
    netmask         = sakura_internet.main.netmask
    default_gateway = sakura_internet.main.gateway
    ip_pool = [{
      start = sakura_internet.main.min_ip_address
      end   = sakura_internet.main.max_ip_address
    }]
  }]
}
