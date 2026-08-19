-- タイムライン（latest/recommendedの穴埋め）、返信ツリー・返信数カウント（parent_post_id IN (...)）向け
CREATE INDEX IF NOT EXISTS idx_posts_parent_created ON posts (parent_post_id, created_at, id);

-- ユーザーの投稿一覧、ユーザーごとの投稿数集計向け
CREATE INDEX IF NOT EXISTS idx_posts_user_parent_created ON posts (user_id, parent_post_id, created_at, id);

-- 投稿ごとのいいね数集計、いいねしたユーザー一覧向け
CREATE INDEX IF NOT EXISTS idx_likes_post_id ON likes (post_id);

-- recommended/trending フィードの「直近N時間」絞り込み向け
CREATE INDEX IF NOT EXISTS idx_likes_created_at ON likes (created_at);

-- 投稿ごとのリポスト数集計向け
CREATE INDEX IF NOT EXISTS idx_reposts_post_id ON reposts (post_id);

-- フォロワー数集計・フォロワー一覧向け（follower_id 起点は複合PRIMARY KEYで足りるため対象外）
CREATE INDEX IF NOT EXISTS idx_follows_followee_id ON follows (followee_id);

-- ユーザーごとの通知一覧・件数取得向け
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications (user_id, created_at, id);

-- ユーザーごとの足跡一覧取得向け
CREATE INDEX IF NOT EXISTS idx_footprints_user_id ON footprints (user_id);
