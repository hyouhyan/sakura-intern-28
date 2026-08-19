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
  name            = "intern1313"
  subdomain_label = "intern1313"

  description = "AppRun用のコンテナレジストリ"

  user = local.registry_users
}
