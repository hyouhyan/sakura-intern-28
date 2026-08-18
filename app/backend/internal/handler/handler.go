package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"sakuravel/internal/middleware"
	"sakuravel/internal/model"
	"sakuravel/internal/realtime"
	"strconv"
)

type Handler struct {
	DB *sql.DB
	// CookieSecure が true の場合、セッションCookieに Secure + SameSite=None を付与する。
	// フロントエンドとバックエンドが別オリジン（別サブドメイン等）で動く構成向け。
	CookieSecure bool
	// Notifications はユーザーIDごと、Threads はスレッドのルート投稿IDごとの SSE 購読を管理する。
	Notifications *realtime.Hub
	Threads       *realtime.Hub
	// Shutdown はプロセス終了時に閉じられる。SSE の配信ループはこれを見て戻る。
	Shutdown <-chan struct{}
}

func (h *Handler) respondJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (h *Handler) respondError(w http.ResponseWriter, status int, msg string) {
	h.respondJSON(w, status, map[string]string{"error": msg})
}

func (h *Handler) currentUserID(r *http.Request) (int64, bool) {
	id, ok := r.Context().Value(middleware.UserIDKey).(int64)
	return id, ok
}

func (h *Handler) pagination(r *http.Request) (page, perPage, offset int) {
	page, _ = strconv.Atoi(r.URL.Query().Get("page"))
	if page < 1 {
		page = 1
	}
	perPage, _ = strconv.Atoi(r.URL.Query().Get("per_page"))
	if perPage < 1 || perPage > 50 {
		perPage = 20
	}
	offset = (page - 1) * perPage
	return
}

// fetchUser は users テーブルから1件取得する。閲覧者はリクエストから解決する。
func (h *Handler) fetchUser(r *http.Request, userID int64) (model.User, error) {
	viewerID, _ := h.currentUserID(r)
	return h.fetchUserCtx(r.Context(), userID, viewerID)
}

// fetchUserCtx は閲覧者を明示して users テーブルから1件取得する。
// リクエストの無いバックグラウンド処理から使えるようにするための形。
func (h *Handler) fetchUserCtx(ctx context.Context, userID, viewerID int64) (model.User, error) {
	var u model.User
	err := h.DB.QueryRowContext(ctx,
		`SELECT id, username, display_name, bio, created_at FROM users WHERE id = ?`,
		userID,
	).Scan(&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.CreatedAt)
	if err != nil {
		return u, err
	}
	u.AvatarColor = model.AvatarColor(u.ID)

	// フォロワー数・フォロー数・投稿数を取得
	h.DB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM follows WHERE followee_id = ?`, u.ID,
	).Scan(&u.FollowersCount)

	h.DB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM follows WHERE follower_id = ?`, u.ID,
	).Scan(&u.FollowingCount)

	h.DB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM posts WHERE user_id = ?`, u.ID,
	).Scan(&u.PostCount)

	if viewerID > 0 && viewerID != u.ID {
		h.DB.QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ?)`,
			viewerID, u.ID,
		).Scan(&u.FollowedByMe)
	}

	return u, nil
}

// fetchPost は posts テーブルから1件取得し、関連データを付加する
func (h *Handler) fetchPost(r *http.Request, postID, viewerID int64) (model.Post, error) {
	return h.fetchPostCtx(r.Context(), postID, viewerID)
}

// fetchPostCtx はリクエストの無いバックグラウンド処理からも呼べる fetchPost。
// viewerID が 0 なら閲覧者に依存する項目 (liked_by_me など) は付けない。
func (h *Handler) fetchPostCtx(ctx context.Context, postID, viewerID int64) (model.Post, error) {
	var p model.Post
	var userID int64
	err := h.DB.QueryRowContext(ctx,
		`SELECT id, user_id, content, is_repost, original_post_id, parent_post_id, created_at
		 FROM posts WHERE id = ?`,
		postID,
	).Scan(&p.ID, &userID, &p.Content, &p.IsRepost, &p.OriginalPostID, &p.ParentPostID, &p.CreatedAt)
	if err != nil {
		return p, err
	}

	author, err := h.fetchUserCtx(ctx, userID, viewerID)
	if err != nil {
		return p, err
	}
	p.Author = author

	h.DB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM likes WHERE post_id = ?`, p.ID,
	).Scan(&p.LikesCount)

	h.DB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM reposts WHERE post_id = ?`, p.ID,
	).Scan(&p.RepostsCount)

	p.RepliesCount = h.countRepliesCtx(ctx, p.ID, 0)

	if viewerID > 0 {
		h.DB.QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM likes WHERE user_id = ? AND post_id = ?)`,
			viewerID, p.ID,
		).Scan(&p.LikedByMe)

		h.DB.QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM reposts WHERE user_id = ? AND post_id = ?)`,
			viewerID, p.ID,
		).Scan(&p.RepostedByMe)
	}

	// 返信の場合、返信先の投稿者を解決する
	if p.ParentPostID != nil {
		var username, displayName string
		err := h.DB.QueryRowContext(ctx, `
			SELECT u.username, u.display_name
			FROM posts parent JOIN users u ON u.id = parent.user_id
			WHERE parent.id = ?
		`, *p.ParentPostID).Scan(&username, &displayName)
		if err == nil {
			p.ReplyToUsername = &username
			p.ReplyToDisplayName = &displayName
		}
	}

	// リポストの場合、何をリポストしたか分かるように元投稿を解決する
	if p.IsRepost && p.OriginalPostID != nil && *p.OriginalPostID != p.ID {
		if original, err := h.fetchPostCtx(ctx, *p.OriginalPostID, viewerID); err == nil {
			p.OriginalPost = &original
		}
	}

	return p, nil
}

// maxThreadDepth はスレッドを辿る深さの上限（循環や極端に深いスレッドの保険）。
const maxThreadDepth = 50

// countReplies は投稿にぶら下がる返信の数を返す。ネストした返信も含めた合計。
func (h *Handler) countReplies(r *http.Request, postID int64, depth int) int {
	return h.countRepliesCtx(r.Context(), postID, depth)
}

func (h *Handler) countRepliesCtx(ctx context.Context, postID int64, depth int) int {
	if depth >= maxThreadDepth {
		return 0
	}

	rows, err := h.DB.QueryContext(ctx,
		`SELECT id FROM posts WHERE parent_post_id = ?`, postID)
	if err != nil {
		return 0
	}

	var ids []int64
	for rows.Next() {
		var id int64
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()

	total := len(ids)
	for _, id := range ids {
		total += h.countRepliesCtx(ctx, id, depth+1)
	}
	return total
}

// threadRootID はスレッドの起点となる投稿IDを返す。
func (h *Handler) threadRootID(r *http.Request, postID int64) int64 {
	return h.threadRootIDCtx(r.Context(), postID)
}

func (h *Handler) threadRootIDCtx(ctx context.Context, postID int64) int64 {
	current := postID
	for i := 0; i < maxThreadDepth; i++ {
		var parent *int64
		err := h.DB.QueryRowContext(ctx,
			`SELECT parent_post_id FROM posts WHERE id = ?`, current,
		).Scan(&parent)
		if err != nil || parent == nil {
			return current
		}
		current = *parent
	}
	return current
}

func pathID(r *http.Request, key string) (int64, error) {
	return strconv.ParseInt(r.PathValue(key), 10, 64)
}
