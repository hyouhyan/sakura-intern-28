# コンテナレジストリ本体は infra/terraform-bootstrap で作成・管理する。
# CI (deploy.yml) は apply 前に docker login でレジストリの存在を
# 前提にしており、レジストリ自体をここで作る resource にすると
# 「無いとログインできず、ログインできないと作れない」循環に陥るため、
# ローカルからの手動 apply で完結する bootstrap 側に resource を置き、
# ここでは data source として参照するだけにしている。
data "sakura_container_registry" "intern" {
  name = var.registry_name
}
