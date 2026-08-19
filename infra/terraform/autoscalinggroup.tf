########################################
# オートスケーリンググループ
########################################

locals {
  # さくらのクラウドのフルリゾルバはリージョンごとに異なる。
  # ゾーンに合わないものを指定するとノードが名前解決できない。
  #   石狩 (is1a/is1b/is1c): dns13/dns14.sakura.ad.jp
  #   東京 (tk1a/tk1b)     : dns5/dns6.sakura.ad.jp
  sakura_dns_by_zone = {
    is1a = ["133.242.0.3", "133.242.0.4"]
    is1b = ["133.242.0.3", "133.242.0.4"]
    is1c = ["133.242.0.3", "133.242.0.4"]
    tk1a = ["210.188.224.10", "210.188.224.11"]
    tk1b = ["210.188.224.10", "210.188.224.11"]
  }

  sakura_dns = local.sakura_dns_by_zone[var.zone]
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

locals {
  # ルータが持つ /28 セグメント (例: x.x.x.32/28)
  internet_cidr = "${sakura_internet.main.network_address}/${sakura_internet.main.netmask}"

  # 払い出し可能な範囲を用途ごとに分割して IP の取り合いを防ぐ。
  # /28 の場合: .32 ネットワーク / .33 ゲートウェイ / .34,.35 予約 / .36-.46 利用可 / .47 ブロードキャスト
  worker_ip_start = cidrhost(local.internet_cidr, 4) # ワーカーノード (ASG) 用
  worker_ip_end   = cidrhost(local.internet_cidr, 8)
  lb_ip_start     = cidrhost(local.internet_cidr, 9) # ロードバランサノード用
  lb_ip_end       = cidrhost(local.internet_cidr, 13)
  lb_vip          = cidrhost(local.internet_cidr, 14) # クライアントがアクセスする VIP
}

data "sakura_apprun_dedicated_worker_service_classes" "main" {}

resource "sakura_apprun_dedicated_auto_scaling_group" "main" {
  cluster_id                = sakura_apprun_dedicated_cluster.example.id
  name                      = "SakuravelASG"
  zone                      = var.zone
  worker_service_class_path = data.sakura_apprun_dedicated_worker_service_classes.main.classes[0].path
  name_servers              = local.sakura_dns
  min_nodes                 = var.asg_min_nodes
  max_nodes                 = var.asg_max_nodes

  # NIC は最大 5 枚まで持てる。グローバル側とプライベート側で分けている。
  #
  # NOTE: interfaces を含む ASG の属性はすべて RequiresReplace で、
  # provider 側も Update を実装していない (完全に不変リソース)。
  # NIC を 1 枚増やすだけでも ASG は作り直しになり、ASG を参照している
  # LB も巻き添えで再作成される。数分〜十数分のダウンを伴う。
  interfaces = [
    # eth0: グローバル側。LB からの振り分けと、コンテナレジストリ /
    # コントロールプレーンへの通信はこちらを通る。
    # デフォルト経路もこちらに置く。
    {
      interface_index = 0
      upstream        = sakura_internet.main.vswitch_id
      connects_to_lb  = true
      netmask         = sakura_internet.main.netmask
      default_gateway = sakura_internet.main.gateway
      ip_pool = [{
        start = local.worker_ip_start
        end   = local.worker_ip_end
      }]
    },

    # eth1: プライベート側。DB アプライアンスと同じ vSwitch につなぐ。
    # ルータのない閉じたセグメントなので default_gateway は指定しない。
    # ここにゲートウェイを置くとデフォルト経路が二重になり、
    # グローバル側の通信 (レジストリからの pull 等) が壊れる。
    #
    # interfaces は Set なので全要素のオブジェクト型が揃っている必要がある。
    # default_gateway を省略すると型が合わずエラーになるため null を明示する。
    {
      interface_index = 1
      upstream        = sakura_vswitch.private_net.id
      connects_to_lb  = false
      netmask         = local.private_netmask
      default_gateway = null
      ip_pool = [{
        start = local.app_private_ip_start
        end   = local.app_private_ip_end
      }]
    },
  ]
}
