########################################
# 出力
########################################

output "lb_vip" {
  description = "ロードバランサの VIP。DNS の A レコードはここを指す"
  value       = local.lb_vip
}

output "dns_records" {
  description = <<-EOT
    手動で登録する必要がある DNS レコード。
    Let's Encrypt の証明書取得より前に登録しておくこと。
  EOT
  value = var.enable_tls ? {
    (var.frontend_host) = local.lb_vip
    (var.backend_host)  = local.lb_vip
  } : {}
}

output "frontend_url" {
  description = "フロントエンドの URL"
  value       = local.frontend_url
}

output "backend_url" {
  description = "バックエンド API の URL"
  value       = local.backend_url
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

output "backend_version" {
  description = "作成された backend の version 番号。backend_active_version にこの値を設定して再 apply する"
  value       = sakura_apprun_dedicated_version.backend.version
}

output "frontend_version" {
  description = "作成された frontend の version 番号。frontend_active_version にこの値を設定して再 apply する"
  value       = sakura_apprun_dedicated_version.frontend.version
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

output "backend_application_id" {
  description = "backend アプリケーションの ID。version の有効化 / 無効化に使う"
  value       = sakura_apprun_dedicated_application.backend.id
}

output "frontend_application_id" {
  description = "frontend アプリケーションの ID。version の有効化 / 無効化に使う"
  value       = sakura_apprun_dedicated_application.frontend.id
}

output "registry_fqdn" {
  description = "コンテナレジストリのホスト名。イメージの push 先"
  value       = sakura_container_registry.intern.fqdn
}
