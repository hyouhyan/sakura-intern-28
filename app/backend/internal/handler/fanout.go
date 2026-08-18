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

// RunThreadFanout はスレッドへの新しい返信を、DB を経由して購読者に配信する。
//
// 通知と同じ理由で、返信を作ったインスタンスから直接配っても購読者には届かない。
// 各インスタンスが自分の抱えているスレッドについてだけ DB を確認する。
//
// 通知と違い、購読を始めた直後には配信しない。通知のイベントは
// 「取得し直せ」の合図として使えるのに対し、こちらは返信そのものを載せて
// 送るため、既に画面に出ている返信をもう一度送ると二重に表示されうる。
// そのため最初の観測では基準を作るだけにして、以降に増えた分だけを流す。
func (h *Handler) RunThreadFanout(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// スレッドのルート投稿ID -> 最後に配信した返信ID
	delivered := map[int64]int64{}

	log.Printf("thread fanout started (interval=%s)", interval)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.fanoutThreadReplies(ctx, delivered)
		}
	}
}

func (h *Handler) fanoutThreadReplies(ctx context.Context, delivered map[int64]int64) {
	roots := h.Threads.Keys()
	if len(roots) == 0 {
		clear(delivered)
		return
	}

	// 誰も見ていないスレッドの記録を捨てる
	watched := make(map[int64]struct{}, len(roots))
	for _, root := range roots {
		watched[root] = struct{}{}
	}
	for root := range delivered {
		if _, ok := watched[root]; !ok {
			delete(delivered, root)
		}
	}

	for _, root := range roots {
		latestID, err := h.latestReplyInThread(ctx, root)
		if err != nil {
			log.Printf("thread fanout (root=%d): %v", root, err)
			continue
		}
		if latestID == 0 {
			continue // まだ返信が無いスレッド
		}

		prev, known := delivered[root]
		delivered[root] = latestID
		if !known || latestID <= prev {
			// 初回は基準を作るだけ。増えていなければ何もしない。
			continue
		}

		// 購読者ごとに閲覧者が違うため、閲覧者に依存する項目は付けずに配る。
		post, err := h.fetchPostCtx(ctx, latestID, 0)
		if err != nil {
			continue
		}
		h.Threads.Publish(root, realtime.Event{Type: "reply", Data: post})
	}
}

// latestReplyInThread はルート投稿にぶら下がる返信のうち、最も新しいものの ID を返す。
// 返信が1件も無ければ 0 を返す。
//
// 返信は入れ子になるため、ルートから再帰的に子を辿る。
// 深さは maxThreadDepth で打ち切る (親子関係が循環していても止まるように)。
func (h *Handler) latestReplyInThread(ctx context.Context, rootID int64) (int64, error) {
	var latest int64
	err := h.DB.QueryRowContext(ctx, `
		WITH RECURSIVE thread AS (
			SELECT id, 0 AS depth FROM posts WHERE id = ?
			UNION ALL
			SELECT p.id, t.depth + 1
			FROM posts p JOIN thread t ON p.parent_post_id = t.id
			WHERE t.depth < ?
		)
		SELECT COALESCE(MAX(id), 0) FROM thread WHERE depth > 0
	`, rootID, maxThreadDepth).Scan(&latest)
	if err != nil {
		return 0, err
	}
	return latest, nil
}
