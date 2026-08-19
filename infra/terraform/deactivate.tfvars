# nginx アプリのバージョンを無効化するための変数ファイル。
#
# -var では null を渡せない (文字列 "null" になり number に変換できない) ため、
# 明示的にこのファイルを指定する:
#
#   terraform apply -var-file=deactivate.tfvars
#
# 用途:
#   - application を新規作成する初回 apply (Create 時に active_version は設定できない)
#   - version を作り直す前の無効化 (アクティブな version は削除できない)
nginx_active_version = null
