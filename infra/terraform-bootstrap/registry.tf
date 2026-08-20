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
  subdomain_label = var.registry_name

  description = "AppRun用のコンテナレジストリ"

  user = local.registry_users
}

########################################
# 初期イメージ投入
########################################
# infra/terraform 側の CI (deploy.yml) は apply 前に
# 「backend/frontend イメージがレジストリに存在するか」を確認する
# (Verify backend/frontend images exist in registry)。
# レジストリを作成した直後はイメージが1つも無くこの確認に失敗するため、
# レジストリ作成と同じ bootstrap (ローカルの手動 apply) の中で、配布元の
# レジストリ (source_registry_host) からイメージを取得し、自分たちの
# レジストリへ push しておく。
#
# docker login を経由する処理のため、レジストリ作成同様 CI には置けず
# (docker login がレジストリの存在を前提にする循環依存になる)、
# ローカル apply で完結する bootstrap 側に置く。
#
# frontend はこのリポジトリ内でビルドされないため常に配布元からの
# シードが必要。backend は deploy.yml が継続的に push するが、
# bootstrap 初回 apply の時点ではまだ1度も push されていないため、
# 同様にベースラインとして投入する (var.seed_images で調整可能)。

resource "terraform_data" "seed_registry_image" {
  for_each = toset(var.seed_images)

  # レジストリが再作成された場合、またはシード対象イメージの一覧が
  # 変わった場合のみ再実行する。通常の terraform apply では変化しないため
  # pull/push は繰り返されない。
  triggers_replace = {
    registry_fqdn = sakura_container_registry.intern.fqdn
    image         = each.value
  }

  provisioner "local-exec" {
    command = "\"${path.module}/scripts/seed_registry_image.sh\" ${each.value}"

    # 認証情報はここでのみ渡す。値は sensitive 変数由来なので
    # terraform plan/apply の出力では (sensitive value) としてマスクされる。
    environment = {
      SOURCE_REGISTRY_HOST     = var.source_registry_host
      SOURCE_REGISTRY_USERNAME = var.source_registry_username
      SOURCE_REGISTRY_PASSWORD = var.source_registry_password
      DEST_REGISTRY_HOST       = sakura_container_registry.intern.fqdn
      DEST_REGISTRY_USERNAME   = "ci"
      DEST_REGISTRY_PASSWORD   = var.registry_ci_user_password
    }
  }
}
