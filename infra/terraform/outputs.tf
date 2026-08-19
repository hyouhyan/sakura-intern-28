########################################
# 出力
########################################

output "lb_vip" {
  description = "ロードバランサの VIP。ここにアクセスすると nginx に振り分けられる"
  value       = local.lb_vip
}

output "lb_endpoint" {
  description = "動作確認用の URL"
  value       = "http://${local.lb_vip}/"
}

output "internet_cidr" {
  description = "ルータが持つグローバル IP のセグメント"
  value       = local.internet_cidr
}

output "ip_allocation" {
  description = "セグメント内の IP 割り当て内訳"
  value = {
    gateway  = sakura_internet.main.gateway
    worker   = "${local.worker_ip_start} - ${local.worker_ip_end}"
    lb_nodes = "${local.lb_ip_start} - ${local.lb_ip_end}"
    lb_vip   = local.lb_vip
  }
}

output "nginx_version" {
  description = "作成された version 番号。nginx_active_version にこの値を設定して再 apply する"
  value       = sakura_apprun_dedicated_version.nginx.version
}

output "lb_service_class" {
  description = "使用した LB のサービスクラス"
  value       = data.sakura_apprun_dedicated_lb_service_classes.main.classes[0]
}

output "private_net" {
  description = "プライベートネットワーク (アプリコンテナ <-> DB) の IP 割り当て"
  value = {
    vswitch_id = sakura_vswitch.private_net.id
    cidr       = var.private_net_cidr
    database   = "${local.db_private_ip}:${var.db_port}"
    app_nodes  = "${local.app_private_ip_start} - ${local.app_private_ip_end}"
    allowed    = var.db_private_net_allow_cidr
  }
}
