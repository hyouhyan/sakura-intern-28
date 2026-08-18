locals {
	registry_users = [
		{
			name                = "ci"
			password_wo         = var.registry_ci_user_password
			password_wo_version = 1
			permission          = "all"
		},
		{
			name                = "apprun"
			password_wo         = var.registry_apprun_user_password
			password_wo_version = 1
			permission          = "readonly"
		}
	]
}

resource "sakura_container_registry" "intern" {
	name = "intern"
	subdomain_label = "intern"

	description = "AppRun用のコンテナレジストリ"

	user = local.registry_users
}