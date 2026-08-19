########################################
# スイッチ (vSwitch)
########################################

resource "sakura_vswitch" "private_net" {
  name = "intern2026-private-net-sw"
  zone = var.zone
}

locals {
  private_netmask = tonumber(split("/", var.private_net_cidr)[1])

  # AppRun は最大ノード数ぶんのプライベートIPを必要とする。
  app_private_ip_start = cidrhost(var.private_net_cidr, var.app_private_ip_offset)
  app_private_ip_end   = cidrhost(var.private_net_cidr, var.app_private_ip_offset + var.asg_max_nodes - 1)
}
