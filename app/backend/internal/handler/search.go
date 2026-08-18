package handler

import (
	"net/http"
)

func (h *Handler) Search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	searchType := r.URL.Query().Get("type")
	if searchType == "" {
		searchType = "posts"
	}
	page, perPage, offset := h.pagination(r)
	viewerID, _ := h.currentUserID(r)

	if q == "" {
		h.respondError(w, http.StatusBadRequest, "q is required")
		return
	}

	switch searchType {
	case "posts":
		h.searchPosts(w, r, q, viewerID, page, perPage, offset)
	case "users":
		h.searchUsers(w, r, q, page, perPage, offset)
	default:
		h.respondError(w, http.StatusBadRequest, "type must be posts or users")
	}
}

func (h *Handler) searchPosts(w http.ResponseWriter, r *http.Request, q string, viewerID int64, page, perPage, offset int) {
	pattern := "%" + q + "%"
	postIDs, total, err := h.queryIDsWithTotal(r,
		`SELECT id, COUNT(*) OVER() AS total FROM posts
		 WHERE content LIKE ?
		 ORDER BY created_at DESC
		 LIMIT ? OFFSET ?`,
		[]any{pattern, perPage, offset}, offset,
		`SELECT COUNT(*) FROM posts WHERE content LIKE ?`, []any{pattern},
	)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	postsByID, err := h.fetchPostsBatch(r, postIDs, viewerID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	posts := make([]any, 0, len(postIDs))
	for _, postID := range postIDs {
		if p, ok := postsByID[postID]; ok {
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

func (h *Handler) searchUsers(w http.ResponseWriter, r *http.Request, q string, page, perPage, offset int) {
	pattern := "%" + q + "%"
	userIDs, total, err := h.queryIDsWithTotal(r,
		`SELECT id, COUNT(*) OVER() AS total FROM users
		 WHERE username LIKE ? OR display_name LIKE ?
		 ORDER BY id
		 LIMIT ? OFFSET ?`,
		[]any{pattern, pattern, perPage, offset}, offset,
		`SELECT COUNT(*) FROM users WHERE username LIKE ? OR display_name LIKE ?`, []any{pattern, pattern},
	)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	usersByID, err := h.fetchUsersBatch(r, userIDs)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	users := make([]any, 0, len(userIDs))
	for _, uid := range userIDs {
		if u, ok := usersByID[uid]; ok {
			users = append(users, u)
		}
	}

	h.respondJSON(w, http.StatusOK, map[string]any{
		"users":    users,
		"total":    total,
		"page":     page,
		"per_page": perPage,
	})
}
