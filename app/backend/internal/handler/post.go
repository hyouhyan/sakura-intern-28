package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
)

func (h *Handler) GetTimeline(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)
	page, perPage, offset := h.pagination(r)
	feed := r.URL.Query().Get("feed")

	var ids []int64
	var total int
	var err error

	// 返信（parent_post_id あり）はスレッド画面でのみ表示するためタイムラインから除く
	switch feed {
	case "latest":
		ids, total, err = h.queryIDsWithTotal(r,
			`SELECT id, COUNT(*) OVER() AS total FROM posts
			 WHERE parent_post_id IS NULL
			 ORDER BY created_at DESC, id DESC
			 LIMIT ? OFFSET ?`,
			[]any{perPage, offset}, offset,
			`SELECT COUNT(*) FROM posts WHERE parent_post_id IS NULL`, nil,
		)
	case "recommended":
		ids, total, err = h.recommendedTimelinePage(r, offset, perPage)
	default: // "following"
		ids, total, err = h.queryIDsWithTotal(r,
			`SELECT id, COUNT(*) OVER() AS total FROM posts
			 WHERE parent_post_id IS NULL
			   AND user_id IN (
				SELECT followee_id FROM follows WHERE follower_id = ?
			)
			 ORDER BY created_at DESC, id DESC
			 LIMIT ? OFFSET ?`,
			[]any{myID, perPage, offset}, offset,
			`SELECT COUNT(*) FROM posts
			 WHERE parent_post_id IS NULL
			   AND user_id IN (
				SELECT followee_id FROM follows WHERE follower_id = ?
			)`, []any{myID},
		)
	}
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	postsByID, err := h.fetchPostsBatch(r, ids, myID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	posts := make([]any, 0, len(ids))
	for _, id := range ids {
		if p, ok := postsByID[id]; ok {
			posts = append(posts, p)
		}
	}

	h.respondJSON(w, http.StatusOK, map[string]any{
		"posts":    posts,
		"total":    total,
		"page":     page,
		"per_page": perPage,
	})
}

// recommendedTimelinePage は recommended フィードの1ページ分を、キャッシュ
// 済みの上位ランキングから切り出す。ランキングは recommendedCacheSize 件
// までしか保持していないため、それより深いページを要求された場合は空配列
// を返す（total は正しい総投稿数のまま）。
func (h *Handler) recommendedTimelinePage(r *http.Request, offset, perPage int) ([]int64, int, error) {
	rankedIDs, err := h.recommendedRankedIDs(r)
	if err != nil {
		return nil, 0, err
	}

	var total int
	if err := h.DB.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM posts WHERE parent_post_id IS NULL`,
	).Scan(&total); err != nil {
		return nil, 0, err
	}

	if offset >= len(rankedIDs) {
		return nil, total, nil
	}
	end := offset + perPage
	if end > len(rankedIDs) {
		end = len(rankedIDs)
	}
	return rankedIDs[offset:end], total, nil
}

func (h *Handler) CreatePost(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)

	var req struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.respondError(w, http.StatusBadRequest, "invalid request")
		return
	}
	if req.Content == "" || len([]rune(req.Content)) > 140 {
		h.respondError(w, http.StatusBadRequest, "content must be 1-140 characters")
		return
	}

	res, err := h.DB.ExecContext(r.Context(),
		`INSERT INTO posts (user_id, content) VALUES (?, ?)`,
		myID, req.Content,
	)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	postID, err := res.LastInsertId()
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	post, _ := h.fetchPost(r, postID, myID)
	h.respondJSON(w, http.StatusCreated, map[string]any{"post": post})
}

func (h *Handler) GetUserPosts(w http.ResponseWriter, r *http.Request) {
	userID, err := pathID(r, "user_id")
	if err != nil {
		h.respondError(w, http.StatusBadRequest, "invalid user_id")
		return
	}
	viewerID, _ := h.currentUserID(r)
	page, perPage, offset := h.pagination(r)

	// type=replies なら返信のみ、それ以外は返信を除いた投稿のみを返す
	parentCond := "parent_post_id IS NULL"
	if r.URL.Query().Get("type") == "replies" {
		parentCond = "parent_post_id IS NOT NULL"
	}

	ids, total, err := h.queryIDsWithTotal(r,
		`SELECT id, COUNT(*) OVER() AS total FROM posts WHERE user_id = ? AND `+parentCond+`
		 ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?`,
		[]any{userID, perPage, offset}, offset,
		`SELECT COUNT(*) FROM posts WHERE user_id = ? AND `+parentCond, []any{userID},
	)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	postsByID, err := h.fetchPostsBatch(r, ids, viewerID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	posts := make([]any, 0, len(ids))
	for _, id := range ids {
		if p, ok := postsByID[id]; ok {
			posts = append(posts, p)
		}
	}

	h.respondJSON(w, http.StatusOK, map[string]any{
		"posts":    posts,
		"total":    total,
		"page":     page,
		"per_page": perPage,
	})
}

func (h *Handler) GetPost(w http.ResponseWriter, r *http.Request) {
	postID, err := pathID(r, "id")
	if err != nil {
		h.respondError(w, http.StatusBadRequest, "invalid id")
		return
	}

	viewerID, _ := h.currentUserID(r)
	post, err := h.fetchPost(r, postID, viewerID)
	if err == sql.ErrNoRows {
		h.respondError(w, http.StatusNotFound, "post not found")
		return
	}
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	h.respondJSON(w, http.StatusOK, map[string]any{"post": post})
}

func (h *Handler) DeletePost(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)
	postID, err := pathID(r, "id")
	if err != nil {
		h.respondError(w, http.StatusBadRequest, "invalid id")
		return
	}

	res, err := h.DB.ExecContext(r.Context(),
		`DELETE FROM posts WHERE id = ? AND user_id = ?`, postID, myID,
	)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		h.respondError(w, http.StatusNotFound, "post not found or not yours")
		return
	}
	h.respondJSON(w, http.StatusOK, map[string]string{"message": "deleted"})
}
