########################################
# スイッチ (vSwitch)
########################################
# AppRun のワーカーノードとデータベースアプライアンスを閉じたネットワークで
# 接続するためのスイッチ。
#
# ワーカーノードはグローバル側 (sakura_internet 側のスイッチ) にも NIC を
# 持っており、コンテナレジストリやコントロールプレーンへの通信はそちらを
# 通る。そのため、このスイッチにサービスエンドポイントゲートウェイ (SEG) を
# 有効化する必要はない。
# SEG が要るのは、ワーカーノードをプライベート NIC だけで構成して
# グローバル経路を持たせない場合。

resource "sakura_vswitch" "private_net" {
  name = "intern2026-private-net-sw"
  zone = var.zone
}

locals {
  # var.private_net_cidr は "192.168.1.0/24" のようにセグメントで指定する。
  private_netmask = tonumber(split("/", var.private_net_cidr)[1])

  # AppRun は最大ノード数ぶんのプライベートIPを必要とする。
  app_private_ip_start = cidrhost(var.private_net_cidr, var.app_private_ip_offset)
  app_private_ip_end   = cidrhost(var.private_net_cidr, var.app_private_ip_offset + var.asg_max_nodes - 1)

  # DB アプライアンスのプライベート IP (db_private_net_cidr のホスト部)。
  # database.tf の ip_address と、backend に渡す DATABASE_URL の両方で使う。
  db_private_ip = split("/", var.db_private_net_cidr)[0]
}
