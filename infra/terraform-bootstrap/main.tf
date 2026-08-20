########################################
# Terraform state 保存用オブジェクトストレージ
########################################
# さくらのオブジェクトストレージは S3 互換 API を提供するが、条件付き書き込み
# (If-None-Match) 未対応のため Terraform S3 backend の use_lockfile は使えない。
# → 排他ロックは GitHub Actions の concurrency グループ側で行う
#   (.github/workflows/deploy.yml)。
# 参考: https://github.com/sacloud/terraform-provider-sakura/blob/main/docs/guides/object-storage-for-tf-backend.md

data "sakura_object_storage_site" "this" {
  id = var.object_storage_site_id
}

resource "sakura_object_storage_bucket" "tfstate" {
  name    = var.bucket_name
  site_id = data.sakura_object_storage_site.this.id
}

resource "sakura_object_storage_permission" "tfstate" {
  name    = "${var.bucket_name}-rw"
  site_id = data.sakura_object_storage_site.this.id

  bucket_controls = [{
    bucket    = sakura_object_storage_bucket.tfstate.name
    can_read  = true
    can_write = true
  }]
}
