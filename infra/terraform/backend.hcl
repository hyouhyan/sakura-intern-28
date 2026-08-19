# 最初にこのファイルをコピーして編集します
# cp backend.hcl.example backend.hcl
#
# 使い方 (terraform init 時に -backend-config で読み込む):
#   terraform init -backend-config=backend.hcl
#
# backend "s3" ブロック (terraform.tf) は変数を参照できないため、
# access_key / secret_key はここで指定するか AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY 環境変数で供給する。
#
# 値は infra/terraform-bootstrap を apply した際の出力から取得する:
#   terraform -chdir=../terraform-bootstrap output -raw access_key
#   terraform -chdir=../terraform-bootstrap output -raw secret_key

access_key = "********"
secret_key = "**********"
