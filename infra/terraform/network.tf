########################################
# スイッチ (vSwitch)
########################################
# アプリケーションコンテナ (AppRun のワーカーノード) とデータベース
# アプライアンスを閉じたネットワークで接続するためのスイッチ。
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

  # ワーカーノードのプライベート側 IP の払い出し範囲。
  # AppRun はコンテナ 1 個につきノード 1 台を割り当てるので、
  # 最大ノード数と同じ数のアドレスを確保する。
  # DB アプライアンスやゲートウェイと重ならない位置から始めること
  # (詳細は variables.tf の app_private_ip_offset を参照)。
  app_private_ip_start = cidrhost(var.private_net_cidr, var.app_private_ip_offset)
  app_private_ip_end   = cidrhost(var.private_net_cidr, var.app_private_ip_offset + var.asg_max_nodes - 1)

  # DB アプライアンスのプライベート IP (db_private_net_cidr のホスト部)。
  db_private_ip = split("/", var.db_private_net_cidr)[0]
}
