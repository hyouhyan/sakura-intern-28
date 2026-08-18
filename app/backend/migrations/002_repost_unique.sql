-- リポストは1ユーザーにつき1投稿までなので posts 側にも一意制約を付ける。
-- 制約が無いと ON DUPLICATE KEY が発火せず、同じ投稿のリポスト行が何行でも作られる。
-- original_post_id が NULL の通常投稿は一意判定の対象外（NULL 同士は重複扱いにならない）。

-- 既存の重複を最も古い1件に寄せてから制約を張る。
DELETE p FROM posts p
JOIN (
    SELECT user_id, original_post_id, MIN(id) AS keep_id
    FROM posts
    WHERE is_repost = TRUE AND original_post_id IS NOT NULL
    GROUP BY user_id, original_post_id
    HAVING COUNT(*) > 1
) d
  ON p.user_id = d.user_id
 AND p.original_post_id = d.original_post_id
 AND p.id <> d.keep_id
WHERE p.is_repost = TRUE;

ALTER TABLE posts
    ADD UNIQUE KEY uk_posts_repost (user_id, original_post_id);
