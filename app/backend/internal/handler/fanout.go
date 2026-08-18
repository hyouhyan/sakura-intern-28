package handler

import (
	"context"
	"log"
	"strings"
	"time"

	"sakuravel/internal/realtime"
)

// RunNotificationFanout は自分に繋がっている購読者向けに、DB を経由して通知を配信する。
//
// 複数インスタンス構成では、通知を作ったインスタンスと購読者が繋がっている
// インスタンスが一致しない。Hub はプロセス内の map なので、作った側から
// 直接配ってもほとんどの場合は届かない。
// そこで各インスタンスが定期的に DB を確認し、自分が抱えている購読者の分だけを
// 自分の Hub に流す。インスタンス同士は一切通信しない。
//
// ctx が終了するまで戻らないので、goroutine で起動すること。
func (h *Handler) RunNotificationFanout(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// ユーザーID -> 最後に配信した通知ID
	delivered := map[int64]int64{}

	log.Printf("notification fanout started (interval=%s)", interval)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.fanoutNotifications(ctx, delivered)
		}
	}
}

func (h *Handler) fanoutNotifications(ctx context.Context, delivered map[int64]int64) {
	userIDs := h.Notifications.Keys()
	if len(userIDs) == 0 {
		// 購読者が1人もいないインスタンスは DB を触らない
		clear(delivered)
		return
	}

	latest, err := h.latestNotifications(ctx, userIDs)
	if err != nil {
		log.Printf("notification fanout: %v", err)
		return
	}

	// 接続が切れた利用者の記録を捨てる。放置すると際限なく増える。
	connected := make(map[int64]struct{}, len(userIDs))
	for _, id := range userIDs {
		connected[id] = struct{}{}
	}
	for id := range delivered {
		if _, ok := connected[id]; !ok {
			delete(delivered, id)
		}
	}

	for _, n := range latest {
		prev, known := delivered[n.userID]
		if known && n.id <= prev {
			continue
		}
		delivered[n.userID] = n.id

		// 初めて見る購読者にも1度流す。再接続の直後にこれが効いて、
		// 切れていた間に増えた通知の取得をクライアントに促せる。
		h.Notifications.Publish(n.userID, realtime.Event{
			Type: "notification",
			Data: map[string]any{"type": n.ntype, "post_id": n.postID},
		})
	}
}

// latestNotification は利用者ごとの最も新しい通知1件。
type latestNotification struct {
	userID int64
	id     int64
	ntype  string
	postID *int64
}

// latestNotifications は指定した利用者それぞれの最新の通知を1件ずつ返す。
//
// 「前回見た ID より大きい行」を追うのではなく、常に現時点の最新1件を取り直す。
// AUTO_INCREMENT の採番順とコミット順はずれることがあり
// (id 100 が先にコミットされ、あとから id 99 がコミットされる)、
// 差分を追う作りだと、その行を飛ばしてしまうため。
func (h *Handler) latestNotifications(ctx context.Context, userIDs []int64) ([]latestNotification, error) {
	placeholders := strings.TrimPrefix(strings.Repeat(",?", len(userIDs)), ",")
	args := make([]any, 0, len(userIDs))
	for _, id := range userIDs {
		args = append(args, id)
	}

	rows, err := h.DB.QueryContext(ctx, `
		SELECT n.user_id, n.id, n.type, n.post_id
		FROM notifications n
		JOIN (
			SELECT user_id, MAX(id) AS max_id
			FROM notifications
			WHERE user_id IN (`+placeholders+`)
			GROUP BY user_id
		) latest ON latest.user_id = n.user_id AND latest.max_id = n.id
	`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []latestNotification
	for rows.Next() {
		var n latestNotification
		if err := rows.Scan(&n.userID, &n.id, &n.ntype, &n.postID); err != nil {
			return nil, err
		}
		result = append(result, n)
	}
	return result, rows.Err()
}
