########################################
# 稼働状況の確認用 (デバッグ)
########################################

data "sakura_apprun_dedicated_worker_nodes" "main" {
  cluster_id            = sakura_apprun_dedicated_cluster.main.id
  auto_scaling_group_id = sakura_apprun_dedicated_auto_scaling_group.main.id
}

data "sakura_apprun_dedicated_lb_nodes" "main" {
  cluster_id            = sakura_apprun_dedicated_cluster.main.id
  auto_scaling_group_id = sakura_apprun_dedicated_auto_scaling_group.main.id
  lb_id                 = sakura_apprun_dedicated_lb.main.id
}

output "worker_nodes" {
  description = "ワーカーノードの状態と稼働中のコンテナ"
  value = [
    for n in data.sakura_apprun_dedicated_worker_nodes.main.nodes : {
      status     = n.status
      healthy    = n.healthy
      creating   = n.creating
      draining   = n.draining
      error      = n.create_error_message
      addresses  = flatten([for i in coalesce(n.network_interfaces, []) : i.addresses])
      containers = n.running_containers
    }
  ]
}

output "lb_nodes" {
  description = "ロードバランサノードの状態"
  value = [
    for n in data.sakura_apprun_dedicated_lb_nodes.main.nodes : {
      status    = n.status
      error     = n.create_error_message
      addresses = flatten([for i in coalesce(n.interfaces, []) : i.addresses])
    }
  ]
}
