package handler

import (
	"encoding/json"
	"net/http"
)

func (h *Handler) Repost(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)

	var req struct {
		PostID int64 `json:"post_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.respondError(w, http.StatusBadRequest, "invalid request")
		return
	}

	// reposts と posts は必ず一緒に増減させる。片方だけ書けた状態になると
	// リポスト数と実際にタイムラインへ流れる投稿が食い違う。
	tx, err := h.DB.BeginTx(r.Context(), nil)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(r.Context(),
		`INSERT INTO reposts (user_id, post_id) VALUES (?, ?)
		 ON DUPLICATE KEY UPDATE user_id = user_id`,
		myID, req.PostID,
	); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	if _, err := tx.ExecContext(r.Context(),
		`INSERT INTO posts (user_id, is_repost, original_post_id)
		 VALUES (?, TRUE, ?)
		 ON DUPLICATE KEY UPDATE id = id`,
		myID, req.PostID,
	); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	// 通知の送信先。元投稿が消えていれば通知は送らない。
	var postOwnerID int64
	ownerErr := tx.QueryRowContext(r.Context(),
		`SELECT user_id FROM posts WHERE id = ?`, req.PostID,
	).Scan(&postOwnerID)

	var count int
	if err := tx.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM reposts WHERE post_id = ?`, req.PostID,
	).Scan(&count); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	if err := tx.Commit(); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	// 通知はコミット後に送る。トランザクション中に h.DB を触ると
	// 接続プールを使い切って自分自身を待つ形になりうる。
	if ownerErr == nil {
		createNotification(h, r, postOwnerID, "repost", myID, &req.PostID)
	}

	h.respondJSON(w, http.StatusOK, map[string]int{"reposts_count": count})
}

func (h *Handler) UnRepost(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)
	postID, err := pathID(r, "post_id")
	if err != nil {
		h.respondError(w, http.StatusBadRequest, "invalid post_id")
		return
	}

	tx, err := h.DB.BeginTx(r.Context(), nil)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(r.Context(),
		`DELETE FROM reposts WHERE user_id = ? AND post_id = ?`, myID, postID,
	); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	if _, err := tx.ExecContext(r.Context(),
		`DELETE FROM posts WHERE user_id = ? AND original_post_id = ? AND is_repost = TRUE`,
		myID, postID,
	); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	var count int
	if err := tx.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM reposts WHERE post_id = ?`, postID,
	).Scan(&count); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	if err := tx.Commit(); err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	h.respondJSON(w, http.StatusOK, map[string]int{"reposts_count": count})
}
