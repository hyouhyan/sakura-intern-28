-- notifications は user_id で絞る問い合わせしか無いのに索引が主キーだけで、
-- 通知一覧・未読件数の取得が毎回フルスキャンになっていた。
-- 複数インスタンス構成では各インスタンスが定期的に最新の通知を確認するため、
-- 索引が無いままだと行数の増加がそのまま負荷になる。
--
-- (user_id, id) の複合にしておくと、利用者ごとの最新通知を求める
-- MAX(id) が索引の末尾を見るだけで済む。
ALTER TABLE notifications
    ADD INDEX idx_notifications_user_id (user_id, id);
