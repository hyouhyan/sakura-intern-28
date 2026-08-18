variable users {
	type = list(object({
		name = string
		password = string
		permission = string
	}))
	default = [
		{
			name = "ci"
			password = CI_PASSWORD
			permission = "all"
		},
		{
			name = "apprun"
			password = registry_apprun_user_password
			permission = "pull"
		}
	]
}

resource "sakura_container_registry" "intern" {
	name = "intern"
	subdomain_label = "?"

	description = "AppRun用のコンテナレジストリ"
	
	dynamic user{
		for_each = var.users
		content {
			name = user.value.name
			password = user.value.password
			permission = user.value.permission
		}
	}
}