locals {
  registry_users = [
    {
      name                = "ci"
      password_wo         = var.registry_ci_user_password
      password_wo_version = 1
      permission          = "all"
    },
    {
      name                = var.registry_apprun_user_name
      password_wo         = var.registry_apprun_user_password
      password_wo_version = 1
      permission          = "readonly"
    }
  ]
}

resource "sakura_container_registry" "intern" {
  # subdomain_label は sakuracr.jp 全体で一意。他アカウントで使用済みの名前は
  # "registry_name: すでに利用されています" で作成に失敗する。
  # 環境ごとに別のレジストリを使えるよう変数にしている。
  name            = var.registry_name
  subdomain_label = var.registry_subdomain_label

  description = "AppRun用のコンテナレジストリ"

  user = local.registry_users
}
