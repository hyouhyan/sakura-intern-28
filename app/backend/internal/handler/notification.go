package handler

import (
	"net/http"
	"sakuravel/internal/realtime"
)

func (h *Handler) GetNotifications(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)
	page, perPage, offset := h.pagination(r)

	// type で種別を絞る（reply / like / repost / follow / footprint）。
	// 空または all のときは全種別を返す。
	typeCond := ""
	typeArgs := []any{}
	if t := r.URL.Query().Get("type"); t != "" && t != "all" {
		typeCond = " AND type = ?"
		typeArgs = append(typeArgs, t)
	}

	listArgs := append([]any{myID}, typeArgs...)
	listArgs = append(listArgs, perPage, offset)
	rows, err := h.DB.QueryContext(r.Context(), `
		SELECT id, type, actor_id, post_id, is_read, created_at
		FROM notifications
		WHERE user_id = ?`+typeCond+`
		ORDER BY created_at DESC, id DESC
		LIMIT ? OFFSET ?
	`, listArgs...)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	defer rows.Close()

	type notifRow struct {
		id      int64
		ntype   string
		actorID int64
		postID  *int64
		isRead  bool
	}
	var rawNotifs []notifRow
	for rows.Next() {
		var n notifRow
		var createdAt any
		rows.Scan(&n.id, &n.ntype, &n.actorID, &n.postID, &n.isRead, &createdAt)
		rawNotifs = append(rawNotifs, n)
	}

	actorIDs := make([]int64, 0, len(rawNotifs))
	postIDs := make([]int64, 0, len(rawNotifs))
	for _, rn := range rawNotifs {
		actorIDs = append(actorIDs, rn.actorID)
		if rn.postID != nil {
			postIDs = append(postIDs, *rn.postID)
		}
	}

	actorsByID, err := h.fetchUsersBatch(r, actorIDs)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	// 対象投稿の本文の抜粋を付ける。
	// 返信通知の post_id は返信そのものを指すので、返信先の抜粋も添える。
	type postInfo struct {
		content  *string
		parentID *int64
	}
	postInfoByID := make(map[int64]postInfo, len(postIDs))
	if len(postIDs) > 0 {
		placeholders, args := int64InClause(dedupeInt64(postIDs))
		if rows, err := h.DB.QueryContext(r.Context(),
			`SELECT id, content, parent_post_id FROM posts WHERE id IN (`+placeholders+`)`, args...,
		); err == nil {
			for rows.Next() {
				var id int64
				var info postInfo
				rows.Scan(&id, &info.content, &info.parentID)
				postInfoByID[id] = info
			}
			rows.Close()
		}
	}

	var parentIDs []int64
	for _, info := range postInfoByID {
		if info.parentID != nil {
			parentIDs = append(parentIDs, *info.parentID)
		}
	}
	parentContentByID := make(map[int64]*string, len(parentIDs))
	if len(parentIDs) > 0 {
		placeholders, args := int64InClause(dedupeInt64(parentIDs))
		if rows, err := h.DB.QueryContext(r.Context(),
			`SELECT id, content FROM posts WHERE id IN (`+placeholders+`)`, args...,
		); err == nil {
			for rows.Next() {
				var id int64
				var content *string
				rows.Scan(&id, &content)
				parentContentByID[id] = content
			}
			rows.Close()
		}
	}

	notifs := make([]any, 0, len(rawNotifs))
	for _, rn := range rawNotifs {
		actor, ok := actorsByID[rn.actorID]
		if !ok {
			continue
		}

		var excerpt, parentExcerpt *string
		if rn.postID != nil {
			if info, ok := postInfoByID[*rn.postID]; ok {
				excerpt = excerptOf(info.content)
				if info.parentID != nil {
					if content, ok := parentContentByID[*info.parentID]; ok {
						parentExcerpt = excerptOf(content)
					}
				}
			}
		}

		notifs = append(notifs, map[string]any{
			"id":             rn.id,
			"type":           rn.ntype,
			"actor":          actor,
			"post_id":        rn.postID,
			"post_excerpt":   excerpt,
			"parent_excerpt": parentExcerpt,
			"is_read":        rn.isRead,
		})
	}

	var unreadCount int
	h.DB.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM notifications WHERE user_id = ? AND is_read = FALSE`,
		myID,
	).Scan(&unreadCount)

	// total は絞り込み後の件数（ページングに使う）。unread_count はバッジ用なので全種別のまま。
	var total int
	h.DB.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM notifications WHERE user_id = ?`+typeCond,
		append([]any{myID}, typeArgs...)...,
	).Scan(&total)

	h.respondJSON(w, http.StatusOK, map[string]any{
		"notifications": notifs,
		"total":         total,
		"unread_count":  unreadCount,
		"page":          page,
		"per_page":      perPage,
	})
}

func (h *Handler) MarkNotificationsRead(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)
	h.DB.ExecContext(r.Context(),
		`UPDATE notifications SET is_read = TRUE WHERE user_id = ? AND is_read = FALSE`,
		myID,
	)
	h.respondJSON(w, http.StatusOK, map[string]string{"message": "ok"})
}

func (h *Handler) GetUnreadCount(w http.ResponseWriter, r *http.Request) {
	myID, _ := h.currentUserID(r)
	var count int
	h.DB.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM notifications WHERE user_id = ? AND is_read = FALSE`,
		myID,
	).Scan(&count)
	h.respondJSON(w, http.StatusOK, map[string]int{"unread_count": count})
}

// excerptOf は通知一覧に載せる本文の抜粋を返す。
func excerptOf(content *string) *string {
	if content == nil {
		return nil
	}
	const limit = 40
	runes := []rune(*content)
	if len(runes) <= limit {
		return content
	}
	s := string(runes[:limit]) + "…"
	return &s
}

func createNotification(h *Handler, r *http.Request, userID int64, ntype string, actorID int64, postID *int64) {
	if userID == actorID {
		return
	}
	_, err := h.DB.ExecContext(r.Context(),
		`INSERT INTO notifications (user_id, type, actor_id, post_id) VALUES (?, ?, ?, ?)`,
		userID, ntype, actorID, postID,
	)
	if err != nil {
		return
	}

	// 宛先ユーザーが SSE で接続していればバッジ更新用に通知する
	h.Notifications.Publish(userID, realtime.Event{
		Type: "notification",
		Data: map[string]any{"type": ntype, "post_id": postID},
	})
}
