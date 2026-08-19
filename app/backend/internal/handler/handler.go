package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"sakuravel/internal/middleware"
	"sakuravel/internal/model"
	"sakuravel/internal/realtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Handler struct {
	DB *sql.DB
	// CookieSecure が true の場合、セッションCookieに Secure + SameSite=None を付与する。
	// フロントエンドとバックエンドが別オリジン（別サブドメイン等）で動く構成向け。
	CookieSecure bool
	// Notifications はユーザーIDごと、Threads はスレッドのルート投稿IDごとの SSE 購読を管理する。
	Notifications *realtime.Hub
	Threads       *realtime.Hub

	// recommendedMu / recommendedCache は recommended フィードの上位ランキング
	// キャッシュを保護する。集計クエリ自体が重いため、結果を一定時間使い回す。
	recommendedMu    sync.Mutex
	recommendedCache *recommendedCacheEntry
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

// maxThreadDepth はスレッドを辿る深さの上限（循環や極端に深いスレッドの保険）。
const maxThreadDepth = 50

// int64InClause は IN (...) 用のプレースホルダ文字列と引数スライスを組み立てる。
// ids は空でないことを呼び出し側が保証すること。
func int64InClause(ids []int64) (string, []any) {
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return placeholders, args
}

// dedupeInt64 は重複を除いた順序保持済みのスライスを返す。
func dedupeInt64(ids []int64) []int64 {
	seen := make(map[int64]bool, len(ids))
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// queryIDsWithTotal は ID 一覧をページングしつつ、`COUNT(*) OVER()` で
// 総件数も同じクエリで取得する。一覧取得と総件数取得を別クエリにすると
// 同じ条件を2回スキャンすることになるため、ウィンドウ関数でまとめて
// 1回のクエリに収める。
// listQuery は `SELECT id, COUNT(*) OVER() AS total FROM ... LIMIT ? OFFSET ?`
// の形をしていること。ウィンドウ関数は「返ってきた行」に対して算出される
// ため、OFFSET がページ末尾を超えて0件になるケースだけ総件数が取れない。
// この場合のみ countQuery（通常の COUNT(*)）をフォールバックとして実行する。
func (h *Handler) queryIDsWithTotal(r *http.Request, listQuery string, listArgs []any, offset int, countQuery string, countArgs []any) ([]int64, int, error) {
	rows, err := h.DB.QueryContext(r.Context(), listQuery, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var ids []int64
	var total int
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id, &total); err != nil {
			return nil, 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	if len(ids) == 0 && offset > 0 {
		if err := h.DB.QueryRowContext(r.Context(), countQuery, countArgs...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return ids, total, nil
}

// recommendedCacheTTL はランキングキャッシュの有効期間。
// recommendedCacheSize はキャッシュするランキングの件数（per_page 最大50件 × 10ページ分）。
const (
	recommendedCacheTTL  = 30 * time.Second
	recommendedCacheSize = 500
)

type recommendedCacheEntry struct {
	ids       []int64
	expiresAt time.Time
}

// recommendedRankedIDs は直近24時間のいいね数が多い順に並べた投稿IDを
// 最大 recommendedCacheSize 件返す。「ORDER BY COUNT(...) DESC」という
// 集計ソートの性質上、母集団を集計しないと順位が決まらずインデックスだけ
// では解決できないため、結果を一定時間プロセス内メモリにキャッシュして
// 使い回す。sync.Mutex で保護し、キャッシュ切れ時の再計算が同時に何度も
// 走らないようにしている。
func (h *Handler) recommendedRankedIDs(r *http.Request) ([]int64, error) {
	h.recommendedMu.Lock()
	defer h.recommendedMu.Unlock()

	if h.recommendedCache != nil && time.Now().Before(h.recommendedCache.expiresAt) {
		return h.recommendedCache.ids, nil
	}

	ids, err := h.computeRecommendedRankedIDs(r)
	if err != nil {
		return nil, err
	}

	h.recommendedCache = &recommendedCacheEntry{ids: ids, expiresAt: time.Now().Add(recommendedCacheTTL)}
	return ids, nil
}

// computeRecommendedRankedIDs はランキングを実際に集計する。likes を起点に
// JOIN することで posts.id の PRIMARY KEY を使った eq_ref 結合になり、
// 新規インデックス無しで Block Nested Loop（総当たり結合）を回避できる。
// いいねが少なく上位 recommendedCacheSize 件に満たない場合は、残り枠を
// 最新投稿で埋め、常にページが埋まる挙動を維持する。
func (h *Handler) computeRecommendedRankedIDs(r *http.Request) ([]int64, error) {
	rows, err := h.DB.QueryContext(r.Context(), `
		SELECT p.id
		FROM likes l
		JOIN posts p ON p.id = l.post_id
		WHERE l.created_at > NOW() - INTERVAL 24 HOUR AND p.parent_post_id IS NULL
		GROUP BY p.id
		ORDER BY COUNT(*) DESC, p.created_at DESC, p.id DESC
		LIMIT ?
	`, recommendedCacheSize)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}

	if needed := recommendedCacheSize - len(ids); needed > 0 {
		query := `SELECT id FROM posts WHERE parent_post_id IS NULL`
		var args []any
		if len(ids) > 0 {
			placeholders, inArgs := int64InClause(ids)
			query += ` AND id NOT IN (` + placeholders + `)`
			args = append(args, inArgs...)
		}
		query += ` ORDER BY created_at DESC, id DESC LIMIT ?`
		args = append(args, needed)

		fillRows, err := h.DB.QueryContext(r.Context(), query, args...)
		if err != nil {
			return nil, err
		}
		for fillRows.Next() {
			var id int64
			if err := fillRows.Scan(&id); err != nil {
				fillRows.Close()
				return nil, err
			}
			ids = append(ids, id)
		}
		if err := fillRows.Close(); err != nil {
			return nil, err
		}
	}

	return ids, nil
}

// fetchUser は users テーブルから1件取得する
func (h *Handler) fetchUser(r *http.Request, userID int64) (model.User, error) {
	users, err := h.fetchUsersBatch(r, []int64{userID})
	if err != nil {
		return model.User{}, err
	}
	u, ok := users[userID]
	if !ok {
		return model.User{}, sql.ErrNoRows
	}
	return u, nil
}

// fetchUsersBatch は複数ユーザーをまとめて取得する。一覧系エンドポイントで
// ユーザーごとに fetchUser を呼ぶと N+1 クエリになるため、IN句 + GROUP BY で
// 何人分でも定数本のクエリに抑える。
func (h *Handler) fetchUsersBatch(r *http.Request, userIDs []int64) (map[int64]model.User, error) {
	result := make(map[int64]model.User, len(userIDs))
	ids := dedupeInt64(userIDs)
	if len(ids) == 0 {
		return result, nil
	}
	placeholders, args := int64InClause(ids)

	rows, err := h.DB.QueryContext(r.Context(),
		`SELECT id, username, display_name, bio, created_at FROM users WHERE id IN (`+placeholders+`)`,
		args...,
	)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var u model.User
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.CreatedAt); err != nil {
			rows.Close()
			return nil, err
		}
		u.AvatarColor = model.AvatarColor(u.ID)
		result[u.ID] = u
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return result, nil
	}

	// フォロワー数
	if followerRows, err := h.DB.QueryContext(r.Context(),
		`SELECT followee_id, COUNT(*) FROM follows WHERE followee_id IN (`+placeholders+`) GROUP BY followee_id`,
		args...,
	); err == nil {
		for followerRows.Next() {
			var id int64
			var count int
			followerRows.Scan(&id, &count)
			if u, ok := result[id]; ok {
				u.FollowersCount = count
				result[id] = u
			}
		}
		followerRows.Close()
	}

	// フォロー数
	if followingRows, err := h.DB.QueryContext(r.Context(),
		`SELECT follower_id, COUNT(*) FROM follows WHERE follower_id IN (`+placeholders+`) GROUP BY follower_id`,
		args...,
	); err == nil {
		for followingRows.Next() {
			var id int64
			var count int
			followingRows.Scan(&id, &count)
			if u, ok := result[id]; ok {
				u.FollowingCount = count
				result[id] = u
			}
		}
		followingRows.Close()
	}

	// 投稿数
	if postCountRows, err := h.DB.QueryContext(r.Context(),
		`SELECT user_id, COUNT(*) FROM posts WHERE user_id IN (`+placeholders+`) GROUP BY user_id`,
		args...,
	); err == nil {
		for postCountRows.Next() {
			var id int64
			var count int
			postCountRows.Scan(&id, &count)
			if u, ok := result[id]; ok {
				u.PostCount = count
				result[id] = u
			}
		}
		postCountRows.Close()
	}

	// 自分がフォローしているか
	if viewerID, ok := h.currentUserID(r); ok {
		followedArgs := append([]any{viewerID}, args...)
		if followedRows, err := h.DB.QueryContext(r.Context(),
			`SELECT followee_id FROM follows WHERE follower_id = ? AND followee_id IN (`+placeholders+`)`,
			followedArgs...,
		); err == nil {
			for followedRows.Next() {
				var id int64
				followedRows.Scan(&id)
				if u, ok := result[id]; ok && id != viewerID {
					u.FollowedByMe = true
					result[id] = u
				}
			}
			followedRows.Close()
		}
	}

	return result, nil
}

// fetchPost は posts テーブルから1件取得し、関連データを付加する
func (h *Handler) fetchPost(r *http.Request, postID, viewerID int64) (model.Post, error) {
	posts, err := h.fetchPostsBatch(r, []int64{postID}, viewerID)
	if err != nil {
		return model.Post{}, err
	}
	p, ok := posts[postID]
	if !ok {
		return model.Post{}, sql.ErrNoRows
	}
	return p, nil
}

// fetchPostsBatch は複数投稿をまとめて取得し、著者・いいね数・リポスト数・
// 返信数（ネスト込み）・自分の反応・返信先・リポスト元をすべて付加する。
// 一覧系エンドポイントで投稿ごとに fetchPost を呼ぶと1件あたり10クエリ近く
// 発生する N+1 になるため、何件でも定数本のクエリに抑える。
func (h *Handler) fetchPostsBatch(r *http.Request, postIDs []int64, viewerID int64) (map[int64]model.Post, error) {
	result := make(map[int64]model.Post, len(postIDs))
	ids := dedupeInt64(postIDs)
	if len(ids) == 0 {
		return result, nil
	}
	placeholders, args := int64InClause(ids)

	rows, err := h.DB.QueryContext(r.Context(), `
		SELECT id, user_id, content, is_repost, original_post_id, parent_post_id, created_at
		FROM posts WHERE id IN (`+placeholders+`)
	`, args...)
	if err != nil {
		return nil, err
	}
	authorIDOf := make(map[int64]int64, len(ids))
	var authorIDs []int64
	for rows.Next() {
		var p model.Post
		var userID int64
		if err := rows.Scan(&p.ID, &userID, &p.Content, &p.IsRepost, &p.OriginalPostID, &p.ParentPostID, &p.CreatedAt); err != nil {
			rows.Close()
			return nil, err
		}
		result[p.ID] = p
		authorIDOf[p.ID] = userID
		authorIDs = append(authorIDs, userID)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return result, nil
	}

	authors, err := h.fetchUsersBatch(r, authorIDs)
	if err != nil {
		return nil, err
	}
	for id, p := range result {
		p.Author = authors[authorIDOf[id]]
		result[id] = p
	}

	// いいね数
	if likeRows, err := h.DB.QueryContext(r.Context(),
		`SELECT post_id, COUNT(*) FROM likes WHERE post_id IN (`+placeholders+`) GROUP BY post_id`,
		args...,
	); err == nil {
		for likeRows.Next() {
			var id int64
			var count int
			likeRows.Scan(&id, &count)
			if p, ok := result[id]; ok {
				p.LikesCount = count
				result[id] = p
			}
		}
		likeRows.Close()
	}

	// リポスト数
	if repostRows, err := h.DB.QueryContext(r.Context(),
		`SELECT post_id, COUNT(*) FROM reposts WHERE post_id IN (`+placeholders+`) GROUP BY post_id`,
		args...,
	); err == nil {
		for repostRows.Next() {
			var id int64
			var count int
			repostRows.Scan(&id, &count)
			if p, ok := result[id]; ok {
				p.RepostsCount = count
				result[id] = p
			}
		}
		repostRows.Close()
	}

	// 返信数（ネストした返信も含めた合計）。再帰CTEで対象投稿配下の子孫をすべて
	// 辿りつつ、起点となった投稿IDごとに集計する。
	if replyRows, err := h.DB.QueryContext(r.Context(), `
		WITH RECURSIVE reply_tree AS (
			SELECT id, parent_post_id AS origin_id FROM posts WHERE parent_post_id IN (`+placeholders+`)
			UNION ALL
			SELECT p.id, rt.origin_id
			FROM posts p JOIN reply_tree rt ON p.parent_post_id = rt.id
		)
		SELECT origin_id, COUNT(*) FROM reply_tree GROUP BY origin_id
	`, args...); err == nil {
		for replyRows.Next() {
			var id int64
			var count int
			replyRows.Scan(&id, &count)
			if p, ok := result[id]; ok {
				p.RepliesCount = count
				result[id] = p
			}
		}
		replyRows.Close()
	}

	// 自分がいいね・リポストしたか
	if viewerID > 0 {
		if likedRows, err := h.DB.QueryContext(r.Context(),
			`SELECT post_id FROM likes WHERE user_id = ? AND post_id IN (`+placeholders+`)`,
			append([]any{viewerID}, args...)...,
		); err == nil {
			for likedRows.Next() {
				var id int64
				likedRows.Scan(&id)
				if p, ok := result[id]; ok {
					p.LikedByMe = true
					result[id] = p
				}
			}
			likedRows.Close()
		}

		if repostedRows, err := h.DB.QueryContext(r.Context(),
			`SELECT post_id FROM reposts WHERE user_id = ? AND post_id IN (`+placeholders+`)`,
			append([]any{viewerID}, args...)...,
		); err == nil {
			for repostedRows.Next() {
				var id int64
				repostedRows.Scan(&id)
				if p, ok := result[id]; ok {
					p.RepostedByMe = true
					result[id] = p
				}
			}
			repostedRows.Close()
		}
	}

	// 返信の場合、返信先の投稿者を解決する
	var parentIDs []int64
	for _, p := range result {
		if p.ParentPostID != nil {
			parentIDs = append(parentIDs, *p.ParentPostID)
		}
	}
	if len(parentIDs) > 0 {
		parentPlaceholders, parentArgs := int64InClause(dedupeInt64(parentIDs))
		if parentRows, err := h.DB.QueryContext(r.Context(), `
			SELECT parent.id, u.username, u.display_name
			FROM posts parent JOIN users u ON u.id = parent.user_id
			WHERE parent.id IN (`+parentPlaceholders+`)
		`, parentArgs...); err == nil {
			type replyToInfo struct {
				username, displayName string
			}
			infoOf := make(map[int64]replyToInfo, len(parentIDs))
			for parentRows.Next() {
				var id int64
				var info replyToInfo
				parentRows.Scan(&id, &info.username, &info.displayName)
				infoOf[id] = info
			}
			parentRows.Close()

			for id, p := range result {
				if p.ParentPostID == nil {
					continue
				}
				if info, ok := infoOf[*p.ParentPostID]; ok {
					username, displayName := info.username, info.displayName
					p.ReplyToUsername = &username
					p.ReplyToDisplayName = &displayName
					result[id] = p
				}
			}
		}
	}

	// リポストの場合、何をリポストしたか分かるように元投稿を解決する
	var originalIDs []int64
	for _, p := range result {
		if p.IsRepost && p.OriginalPostID != nil && *p.OriginalPostID != p.ID {
			originalIDs = append(originalIDs, *p.OriginalPostID)
		}
	}
	if len(originalIDs) > 0 {
		originals, err := h.fetchPostsBatch(r, dedupeInt64(originalIDs), viewerID)
		if err == nil {
			for id, p := range result {
				if !p.IsRepost || p.OriginalPostID == nil || *p.OriginalPostID == p.ID {
					continue
				}
				if original, ok := originals[*p.OriginalPostID]; ok {
					original := original
					p.OriginalPost = &original
					result[id] = p
				}
			}
		}
	}

	return result, nil
}

// fetchAncestorIDs は投稿の祖先チェーンのIDを、古い順（直接の親が末尾）で返す。
// 再帰CTEで一括取得することで、親を1件ずつ辿る逐次クエリを避ける。
func (h *Handler) fetchAncestorIDs(r *http.Request, postID int64) ([]int64, error) {
	rows, err := h.DB.QueryContext(r.Context(), `
		WITH RECURSIVE ancestors AS (
			SELECT id, parent_post_id, 0 AS depth FROM posts WHERE id = ?
			UNION ALL
			SELECT p.id, p.parent_post_id, a.depth + 1
			FROM posts p JOIN ancestors a ON p.id = a.parent_post_id
			WHERE a.depth + 1 <= ?
		)
		SELECT id FROM ancestors WHERE depth > 0 ORDER BY depth DESC
	`, postID, maxThreadDepth)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// replyEdge は返信ツリーの1ノード分の親子関係と兄弟順ソート用の情報。
type replyEdge struct {
	id           int64
	parentPostID int64
	createdAt    time.Time
}

// fetchDescendantEdges は対象投稿配下の返信をすべて再帰CTEで一括取得し、
// 親投稿IDごとの子投稿ID一覧（作成日時の古い順）を返す。ノードごとに
// 「子を取得する」クエリを1件ずつ発行する逐次探索を避けるため、まず
// idと親子関係だけを安いクエリで辿り、あとで対象ノード全件をまとめて
// バッチ取得する。
func (h *Handler) fetchDescendantEdges(r *http.Request, rootID int64) (map[int64][]int64, error) {
	rows, err := h.DB.QueryContext(r.Context(), `
		WITH RECURSIVE descendants AS (
			SELECT id, parent_post_id, created_at, 0 AS depth FROM posts WHERE parent_post_id = ?
			UNION ALL
			SELECT p.id, p.parent_post_id, p.created_at, d.depth + 1
			FROM posts p JOIN descendants d ON p.parent_post_id = d.id
			WHERE d.depth + 1 <= ?
		)
		SELECT id, parent_post_id, created_at FROM descendants
	`, rootID, maxThreadDepth)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	edgesByParent := make(map[int64][]replyEdge)
	for rows.Next() {
		var e replyEdge
		if err := rows.Scan(&e.id, &e.parentPostID, &e.createdAt); err != nil {
			return nil, err
		}
		edgesByParent[e.parentPostID] = append(edgesByParent[e.parentPostID], e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	childrenOf := make(map[int64][]int64, len(edgesByParent))
	for parentID, edges := range edgesByParent {
		sort.Slice(edges, func(i, j int) bool {
			if !edges[i].createdAt.Equal(edges[j].createdAt) {
				return edges[i].createdAt.Before(edges[j].createdAt)
			}
			return edges[i].id < edges[j].id
		})
		ids := make([]int64, len(edges))
		for i, e := range edges {
			ids[i] = e.id
		}
		childrenOf[parentID] = ids
	}
	return childrenOf, nil
}

// threadRootID はスレッドの起点となる投稿IDを返す。
func (h *Handler) threadRootID(r *http.Request, postID int64) int64 {
	current := postID
	for i := 0; i < maxThreadDepth; i++ {
		var parent *int64
		err := h.DB.QueryRowContext(r.Context(),
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
