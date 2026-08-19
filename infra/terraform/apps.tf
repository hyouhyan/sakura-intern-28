########################################
# アプリケーションの公開設定 (共通)
########################################
#
# TLS 終端は AppRun のロードバランサが行う (nginx などのサイドカーは挟まない)。
# LB は Host ヘッダによる L7 ルーティングをするので、host が異なれば
# 複数のアプリケーションで同じ lb_port (443) を共有できる。
#
#   Browser ──https──> LB :443 ──http──> frontend コンテナ :3000
#            (Host: frontend_host)
#   Browser ──https──> LB :443 ──http──> backend コンテナ :8080
#            (Host: backend_host)
#
# ブラウザは frontend と backend の両方に別オリジンでアクセスするため
# (app/backend/internal/handler/handler.go の CookieSecure のコメントを参照)、
# 双方を HTTPS にしないとセッション Cookie (Secure + SameSite=None) が載らない。
#
# アプリごとの定義は backend.tf / frontend.tf に分けている。

locals {
  # 公開 URL。TLS を切っているときはワーカーノードのグローバル IP に
  # 直接ぶら下がる従来の形にフォールバックする。
  frontend_url = var.enable_tls ? "https://${var.frontend_host}" : "http://${sakura_internet.main.min_ip_address}:3000"
  backend_url  = var.enable_tls ? "https://${var.backend_host}" : "http://${sakura_internet.main.min_ip_address}:8080"
}
