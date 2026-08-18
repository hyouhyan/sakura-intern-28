package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	appdb "sakuravel/internal/db"
	"sakuravel/internal/handler"
	"sakuravel/internal/middleware"
	"sakuravel/internal/realtime"
)

// shutdownTimeout は終了signalを受けてから処理中のリクエストを待つ上限。
// AppRun のようにコンテナが入れ替わる環境では、この時間で片付かなければ
// どのみち強制終了されるため、長く取りすぎても意味がない。
const shutdownTimeout = 15 * time.Second

// defaultFanoutInterval は SSE 配信のために DB を確認する既定の間隔。
// FANOUT_INTERVAL_MS で変更できる。
const defaultFanoutInterval = time.Second

func main() {
	db := appdb.New()
	defer db.Close()

	// SSE の配信ループへ終了を伝えるチャネル。閉じると各ストリームが順に戻る。
	// これが無いと、終わることのない SSE 接続を Shutdown が待ち続けてしまう。
	shutdown := make(chan struct{})

	h := &handler.Handler{
		DB:            db,
		CookieSecure:  os.Getenv("COOKIE_SECURE") == "true",
		Notifications: realtime.NewHub(),
		Threads:       realtime.NewHub(),
		Shutdown:      shutdown,
	}
	auth := &middleware.Auth{DB: db}

	mux := http.NewServeMux()

	// CORS ミドルウェア
	mux.Handle("/", corsMiddleware(routes(h, auth)))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	srv := &http.Server{Addr: ":" + port, Handler: mux}

	// 複数インスタンス構成では、通知を作ったインスタンスと購読者が繋がって
	// いるインスタンスが一致しない。DB を経由して自分の購読者に配信する。
	fanoutCtx, stopFanout := context.WithCancel(context.Background())
	defer stopFanout()
	go h.RunNotificationFanout(fanoutCtx, fanoutInterval())
	go h.RunThreadFanout(fanoutCtx, fanoutInterval())

	go func() {
		log.Printf("starting server on :%s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	// コンテナの入れ替え時には SIGTERM が送られる。受け取ったら新規の受付を
	// 止め、処理中のリクエストが終わるのを待ってから落ちる。
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	stop() // 2度目のsignalは既定動作（即時終了）に戻す

	log.Println("shutting down...")
	stopFanout()
	close(shutdown)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
	log.Println("stopped")
}

// fanoutInterval は SSE 配信のために DB を確認する間隔。
// 短くするほど通知は速くなるが、その分 DB への問い合わせが増える。
func fanoutInterval() time.Duration {
	ms, err := strconv.Atoi(os.Getenv("FANOUT_INTERVAL_MS"))
	if err != nil || ms < 1 {
		return defaultFanoutInterval
	}
	return time.Duration(ms) * time.Millisecond
}

func routes(h *handler.Handler, auth *middleware.Auth) http.Handler {
	mux := http.NewServeMux()

	// ヘルスチェック。ロードバランサが定期的に叩くので DB には触らない。
	// "/{$}" は完全一致なので、未知のパスは従来どおり 404 のまま。
	mux.HandleFunc("GET /{$}", h.Health)
	mux.HandleFunc("GET /healthz", h.Health)

	// 認証
	mux.HandleFunc("POST /register", h.Register)
	mux.HandleFunc("POST /login", h.Login)
	mux.Handle("POST /logout", auth.Required(http.HandlerFunc(h.Logout)))

	// 自分のプロフィール
	mux.Handle("GET /me", auth.Required(http.HandlerFunc(h.GetMe)))

	// 足跡
	mux.Handle("GET /me/footprints", auth.Required(http.HandlerFunc(h.GetFootprints)))

	// ユーザー
	mux.Handle("GET /profile/{user_id}", auth.Optional(http.HandlerFunc(h.GetProfile)))
	mux.Handle("PUT /profile", auth.Required(http.HandlerFunc(h.UpdateProfile)))
	mux.Handle("GET /users/{user_id}/followers", auth.Optional(http.HandlerFunc(h.GetFollowers)))
	mux.Handle("GET /users/{user_id}/following", auth.Optional(http.HandlerFunc(h.GetFollowing)))
	mux.Handle("POST /users/{user_id}/follow", auth.Required(http.HandlerFunc(h.Follow)))
	mux.Handle("DELETE /users/{user_id}/follow", auth.Required(http.HandlerFunc(h.Unfollow)))

	// 投稿
	mux.Handle("GET /posts", auth.Required(http.HandlerFunc(h.GetTimeline)))
	mux.Handle("POST /posts", auth.Required(http.HandlerFunc(h.CreatePost)))
	mux.Handle("GET /posts/{id}", auth.Optional(http.HandlerFunc(h.GetPost)))
	mux.Handle("GET /users/{user_id}/posts", auth.Optional(http.HandlerFunc(h.GetUserPosts)))
	mux.Handle("DELETE /posts/{id}", auth.Required(http.HandlerFunc(h.DeletePost)))

	// 返信（スレッド）
	mux.Handle("POST /replies", auth.Required(http.HandlerFunc(h.CreateReply)))
	mux.Handle("GET /posts/{id}/thread", auth.Optional(http.HandlerFunc(h.GetThread)))
	mux.Handle("GET /posts/{id}/thread/stream", auth.Optional(http.HandlerFunc(h.ThreadStream)))

	// いいね
	mux.HandleFunc("GET /posts/{id}/likes", h.GetLikes)
	mux.Handle("POST /likes", auth.Required(http.HandlerFunc(h.Like)))
	mux.Handle("DELETE /likes/{post_id}", auth.Required(http.HandlerFunc(h.Unlike)))

	// リポスト
	mux.Handle("POST /reposts", auth.Required(http.HandlerFunc(h.Repost)))
	mux.Handle("DELETE /reposts/{post_id}", auth.Required(http.HandlerFunc(h.UnRepost)))

	// 検索
	mux.HandleFunc("GET /search", h.Search)

	// 通知
	mux.Handle("GET /notifications", auth.Required(http.HandlerFunc(h.GetNotifications)))
	mux.Handle("POST /notifications/read", auth.Required(http.HandlerFunc(h.MarkNotificationsRead)))
	mux.Handle("GET /notifications/unread_count", auth.Required(http.HandlerFunc(h.GetUnreadCount)))
	mux.Handle("GET /notifications/stream", auth.Required(http.HandlerFunc(h.NotificationStream)))

	// トレンド
	mux.Handle("GET /trending", auth.Optional(http.HandlerFunc(h.GetTrending)))

	return mux
}

func corsMiddleware(next http.Handler) http.Handler {
	allowedOrigin := os.Getenv("ALLOWED_ORIGIN")
	if allowedOrigin == "" {
		allowedOrigin = "http://localhost:3000"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", allowedOrigin)
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
