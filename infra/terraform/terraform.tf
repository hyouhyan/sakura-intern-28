# terraform.tf
# v3 registry: https://registry.terraform.io/providers/sacloud/sakura/latest

terraform {
  required_version = ">= 1.11"

  required_providers {
    sakura = {
      source  = "sacloud/sakura"
      version = "~> 3.8"
    }
  }

  # Terraform state はさくらのオブジェクトストレージ (S3 互換 API) に保存する。
  # バケットは infra/terraform-bootstrap で作成 (手動での一度きりの apply)。
  # backend ブロックは変数 (var.*) を参照できないため、access_key / secret_key は
  # 下記いずれかで供給する:
  #   - ローカル: backend.hcl (backend.hcl.example をコピーして作成) を
  #     `terraform init -backend-config=backend.hcl` で読み込む
  #   - GitHub Actions: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY 環境変数
  #     (secrets.TFSTATE_ACCESS_KEY_ID / TFSTATE_SECRET_ACCESS_KEY, terraform-apply.yml)
  # さくらのオブジェクトストレージは条件付き書き込み (If-None-Match) 未対応のため
  # use_lockfile は使用不可。排他制御は GitHub Actions の concurrency で行う
  # (.github/workflows/terraform-apply.yml)。
  backend "s3" {
    bucket = "intern-matsu-tfstate"
    key    = "terraform.tfstate"
    region = "jp-north-1"

    endpoints = {
      s3 = "https://s3.isk01.sakurastorage.jp"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
  }
}

provider "sakura" {
  # SAKURA_ACCESS_TOKEN / SAKURA_ACCESS_TOKEN_SECRET の環境変数も利用可能
  token  = var.sakura_access_token
  secret = var.sakura_access_token_secret
  zone   = var.zone
}
