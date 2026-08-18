package handler

import "net/http"

// Health はロードバランサ向けのヘルスチェックに応答する。
//
// DB などの外部依存はあえて確認しない。ここで DB を叩くと、DB 側の
// 一時的な不調で全インスタンスが同時に unhealthy と判定され、
// 振り分け先が1台も残らなくなる。プロセスが生きて応答できることだけを示す。
func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	h.respondJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
