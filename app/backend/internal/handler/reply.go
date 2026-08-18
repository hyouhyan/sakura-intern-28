package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"sakuravel/internal/model"
)

// CreateReply は指定した投稿への返信を作成する。返信も posts の1行として保存する。
func (h *Handler) CreateReply(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)

	var req struct {
		PostID  int64  `json:"post_id"`
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

	parentID := req.PostID
	var parentAuthorID int64
	err := h.DB.QueryRowContext(r.Context(),
		`SELECT user_id FROM posts WHERE id = ?`, parentID,
	).Scan(&parentAuthorID)
	if err == sql.ErrNoRows {
		h.respondError(w, http.StatusNotFound, "post not found")
		return
	}
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	res, err := h.DB.ExecContext(r.Context(),
		`INSERT INTO posts (user_id, content, parent_post_id) VALUES (?, ?, ?)`,
		myID, req.Content, parentID,
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

	// 通知は直接の返信先の著者にのみ送る
	createNotification(h, r, parentAuthorID, "reply", myID, &postID)

	// SSE への配信はここでは行わない。複数インスタンス構成では同じスレッドを
	// 開いている購読者が別のインスタンスに繋がっていることが多く、自分の Hub に
	// 流しても届かない。配信は RunThreadFanout が DB を見て行う。

	h.respondJSON(w, http.StatusCreated, map[string]any{"post": post})
}

// GetThread は対象投稿と、その祖先チェーン・返信ツリーをまとめて返す。
func (h *Handler) GetThread(w http.ResponseWriter, r *http.Request) {
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

	// 祖先の投稿IDを再帰CTEで一括取得する（古い順）
	ancestorIDs, err := h.fetchAncestorIDs(r, postID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	ancestorsByID, err := h.fetchPostsBatch(r, ancestorIDs, viewerID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	ancestors := make([]any, 0, len(ancestorIDs))
	for _, id := range ancestorIDs {
		if a, ok := ancestorsByID[id]; ok {
			ancestors = append(ancestors, a)
		}
	}

	// 返信ツリーは、まず id と親子関係だけを再帰CTEで一括取得し、最後に
	// 対象ノード全件をバッチ取得する（ノードごとに子取得クエリを発行する
	// 逐次探索を避けるため）。
	childrenOf, err := h.fetchDescendantEdges(r, postID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	var descendantIDs []int64
	for _, ids := range childrenOf {
		descendantIDs = append(descendantIDs, ids...)
	}
	descendantsByID, err := h.fetchPostsBatch(r, descendantIDs, viewerID)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	h.respondJSON(w, http.StatusOK, map[string]any{
		"ancestors": ancestors,
		"post":      post,
		"replies":   buildReplyTree(postID, childrenOf, descendantsByID),
	})
}

// buildReplyTree は fetchDescendantEdges / fetchPostsBatch の結果から
// 返信ツリーを組み立てる（DBへの追加問い合わせなし）。
func buildReplyTree(postID int64, childrenOf map[int64][]int64, postsByID map[int64]model.Post) []any {
	nodes := make([]any, 0)
	for _, id := range childrenOf[postID] {
		p, ok := postsByID[id]
		if !ok {
			continue
		}
		nodes = append(nodes, map[string]any{
			"post":    p,
			"replies": buildReplyTree(id, childrenOf, postsByID),
		})
	}
	return nodes
}
