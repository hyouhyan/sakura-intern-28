package handler

import (
	"log"
	"net/http"
)

func recordFootprint(h *Handler, r *http.Request, userID, visitorID int64) {
	if userID == visitorID {
		return
	}
	// 足跡の記録に失敗してもプロフィール表示自体は返したいので、記録だけして続行する
	if _, err := h.DB.ExecContext(r.Context(),
		`INSERT INTO footprints (user_id, visitor_id) VALUES (?, ?)`,
		userID, visitorID,
	); err != nil {
		log.Printf("recordFootprint(user=%d visitor=%d): %v", userID, visitorID, err)
	}
}

func (h *Handler) GetFootprints(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.currentUserID(r)
	if !ok {
		h.respondError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	page, perPage, offset := h.pagination(r)

	rows, err := h.DB.QueryContext(r.Context(), `
		SELECT visitor_id, COUNT(*) AS visit_count, MAX(created_at) AS last_visited, COUNT(*) OVER() AS total
		FROM footprints
		WHERE user_id = ?
		GROUP BY visitor_id
		ORDER BY last_visited DESC, visitor_id DESC
		LIMIT ? OFFSET ?
	`, userID, perPage, offset)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}
	defer rows.Close()

	type fpRow struct {
		visitorID  int64
		visitCount int
	}
	var rawFps []fpRow
	var total int
	for rows.Next() {
		var fp fpRow
		var lastVisited any
		rows.Scan(&fp.visitorID, &fp.visitCount, &lastVisited, &total)
		rawFps = append(rawFps, fp)
	}
	rows.Close()

	// ウィンドウ関数は返ってきた行に対して総件数（グループ数）を付与するため、
	// OFFSET がページ末尾を超えて0件になるケースだけフォールバックで数える。
	if len(rawFps) == 0 && offset > 0 {
		h.DB.QueryRowContext(r.Context(),
			`SELECT COUNT(DISTINCT visitor_id) FROM footprints WHERE user_id = ?`, userID,
		).Scan(&total)
	}

	visitorIDs := make([]int64, len(rawFps))
	for i, rf := range rawFps {
		visitorIDs[i] = rf.visitorID
	}
	visitorsByID, err := h.fetchUsersBatch(r, visitorIDs)
	if err != nil {
		h.respondError(w, http.StatusInternalServerError, "server error")
		return
	}

	fps := make([]any, 0, len(rawFps))
	for _, rf := range rawFps {
		visitor, ok := visitorsByID[rf.visitorID]
		if !ok {
			continue
		}
		fps = append(fps, map[string]any{
			"visitor":     visitor,
			"visit_count": rf.visitCount,
		})
	}

	h.respondJSON(w, http.StatusOK, map[string]any{
		"footprints": fps,
		"total":      total,
		"page":       page,
		"per_page":   perPage,
	})
}
