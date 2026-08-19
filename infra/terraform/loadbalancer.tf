########################################
# ロードバランサ
########################################

data "sakura_apprun_dedicated_lb_service_classes" "main" {}

resource "sakura_apprun_dedicated_lb" "main" {
  cluster_id            = sakura_apprun_dedicated_cluster.main.id
  auto_scaling_group_id = sakura_apprun_dedicated_auto_scaling_group.main.id
  name                  = var.lb_name
  service_class_path    = data.sakura_apprun_dedicated_lb_service_classes.main.classes[0].path
  name_servers          = local.sakura_dns

  interfaces = [{
    interface_index = 0
    upstream        = sakura_internet.main.vswitch_id
    netmask         = sakura_internet.main.netmask
    default_gateway = sakura_internet.main.gateway
    ip_pool = [{
      start = local.lb_ip_start
      end   = local.lb_ip_end
    }]
    vip               = local.lb_vip
    virtual_router_id = 1
  }]
}
