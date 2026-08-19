########################################
# nginx アプリケーション
########################################

resource "sakura_apprun_dedicated_application" "nginx" {
  cluster_id = sakura_apprun_dedicated_cluster.example.id
  name       = var.nginx_app_name

  # NOTE: application の新規作成時のみ null にする必要がある。詳細は
  # variables.tf の nginx_active_version を参照。
  active_version = var.nginx_active_version
}

locals {
  # AppRun 専有型のコンテナは非 root で実行されるため、
  #   - 特権ポート (80 番) には bind できない
  #   - root 所有のパスには書き込めない
  # という制約がある。nginx-unprivileged は 8080 で listen し、
  # /etc/nginx/conf.d を非 root でも書けるように作られたイメージ。
  #
  # どのコンテナが応答したか判別できるよう、識別情報を返す設定を流し込む。
  # $hostname はワーカーノードのホスト名 (全台 "ubuntu") で区別が付かないため、
  # 接続を受け付けたアドレスである $server_addr を主たる識別子に使う。書き込みに失敗しても nginx は
  # 起動させたいので、失敗は握りつぶす (|| true) こと。
  # ここを && でつなぐと書き込み失敗時に nginx が起動せず落ちる。
  nginx_fqdns = var.nginx_hosts == null ? [] : var.nginx_hosts

  # HTTP は IP 直打ちでも確認できるように VIP も Host として受け付ける。
  # HTTPS 側は LE の制約で FQDN のみ。
  nginx_http_hosts = distinct(concat(local.nginx_fqdns, [local.lb_vip]))

  nginx_health_check = {
    path             = "/"
    interval_seconds = 10
    timeout_seconds  = 5
  }

  nginx_entrypoint = <<-EOT
    # /etc/nginx 配下は非 root では書けないため、確実に書ける /tmp に設定を置く。
    # 一時ファイルの出力先と pid も /tmp に向けないと非 root では起動できない。
    { echo 'pid /tmp/nginx.pid;'
      echo 'error_log /dev/stderr warn;'
      echo 'events {}'
      echo 'http {'
      echo '  access_log off;'
      echo '  client_body_temp_path /tmp/nginx-client-body;'
      echo '  proxy_temp_path /tmp/nginx-proxy;'
      echo '  fastcgi_temp_path /tmp/nginx-fastcgi;'
      echo '  uwsgi_temp_path /tmp/nginx-uwsgi;'
      echo '  scgi_temp_path /tmp/nginx-scgi;'
      echo '  server {'
      echo '    listen ${var.nginx_container_port};'
      echo '    listen ${var.nginx_tls_container_port};'
      echo '    location / {'
      echo '      default_type text/plain;'
      echo '      return 200 "backend: $server_addr host=$hostname";'
      echo '    }'
      echo '    location = /db-check {'
      echo '      default_type text/plain;'
      echo '      alias /tmp/db-check.txt;'
      echo '    }'
      echo '  }'
      echo '}'
    } > /tmp/nginx.conf 2>/dev/null || true

    # プライベート vSwitch (ワーカーノードの eth1) 経由で DB アプライアンスに
    # 到達できているかを 10 秒ごとに確認し、結果を /tmp に書き出す。
    # nginx が /db-check でそのまま返すので、LB 越しに疎通を確認できる
    # (AppRun のワーカーノードには SSH で入れないため、疎通確認の手段がこれしかない)。
    #
    # busybox の nc には -z (ポートスキャン) が無いので、接続だけして
    # 標準入力を即 EOF にすることで到達性を判定する。
    printf 'db: probing...\n' > /tmp/db-check.txt 2>/dev/null || true

    if [ -n "$DB_HOST" ]; then
      while :; do
        if nc -w 3 "$DB_HOST" "$DB_PORT" </dev/null >/dev/null 2>&1; then
          db_state=ok
        else
          db_state=ng
        fi

        # hostname -i はコンテナ自身のアドレスを返す。
        # プライベート側のアドレスが見えているかの確認に使う。
        printf 'db: %s (%s:%s) container_ip=%s\n' \
          "$db_state" "$DB_HOST" "$DB_PORT" "$(hostname -i 2>/dev/null)" \
          > /tmp/db-check.txt 2>/dev/null || true

        sleep 10
      done &
    fi

    # 書き込みか設定検証に失敗したらイメージ既定の設定で起動する。
    # ホスト名は出せなくなるが、コンテナを落とさないことを優先する。
    if nginx -t -c /tmp/nginx.conf >/dev/null 2>&1; then
      exec nginx -c /tmp/nginx.conf -g 'daemon off;'
    fi

    exec nginx -g 'daemon off;'
  EOT
}

resource "sakura_apprun_dedicated_version" "nginx" {
  application_id = sakura_apprun_dedicated_application.nginx.id
  image          = var.nginx_image
  cpu            = 500
  memory         = 512

  # 固定数でコンテナを起動する。この台数に対して LB が振り分ける
  scaling_mode = "manual"
  fixed_scale  = var.nginx_replicas

  cmd = ["/bin/sh", "-c", local.nginx_entrypoint]

  # DB への接続情報。プライベート vSwitch 側のアドレスなので、
  # グローバルを経由せずワーカーノードの eth1 から直接届く。
  #
  # NOTE: パスワードは意図的に渡していない。database.tf では password_wo
  # (write-only) を使っており state に残らないが、env_vars の value は
  # secret = true にしても state に平文で入る。実アプリを載せる際は
  # そのトレードオフを承知のうえで secret = true のエントリを足すこと。
  env_vars = [
    {
      key    = "DB_HOST"
      value  = local.db_private_ip
      secret = false
    },
    {
      key    = "DB_PORT"
      value  = tostring(var.db_port)
      secret = false
    },
    {
      key    = "DB_NAME"
      value  = var.db_name
      secret = false
    },
    {
      key    = "DB_USER"
      value  = var.db_username
      secret = false
    },
  ]

  # HTTP と HTTPS で受け付ける Host が異なるので concat で組み立てる。
  # concat するリストの要素は同じ属性を持つ必要があるため、
  # HTTP 側にも use_lets_encrypt を明示している。
  exposed_ports = concat(
    [{
      target_port = var.nginx_container_port # コンテナが listen するポート (非特権)
      lb_port     = 80                       # LB が listen するポート (cluster.tf の ports と対応)

      # protocol=http の lb_port では振り分け対象の Host ヘッダ指定が必須。
      # 未指定だと API が 400 "Missing Host header for HTTP load balancer port" を返す。
      host = local.nginx_http_hosts

      # クラスタに lets_encrypt_email がある場合、LE の HTTP-01 チャレンジが
      # 80 番に来るため、TLS を使う場合でもこのエントリは残す必要がある。
      use_lets_encrypt = false

      health_check = local.nginx_health_check
    }],

    # TLS 終端。LE は IP アドレスに証明書を発行できないので FQDN のみを対象にする。
    # AppRun は exposed_ports 間で target_port の重複を許さない
    # (400 "Target port is duplicated")。そのため HTTPS 側は別ポートに向ける。
    var.nginx_enable_tls ? [{
      target_port      = var.nginx_tls_container_port
      lb_port          = 443
      host             = local.nginx_fqdns
      use_lets_encrypt = true
      health_check     = local.nginx_health_check
    }] : [],
  )

  # LB が出来てから version を作る (lb_port の接続先を確定させるため)
  depends_on = [sakura_apprun_dedicated_lb.main]
}
