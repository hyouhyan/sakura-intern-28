-- NOTE: CHARSET を明示すること。
-- 省略するとサーバー既定の文字セットでテーブルが作られる。開発環境の
-- MariaDB コンテナは既定が utf8mb4 なので問題にならないが、さくらの
-- データベースアプライアンスは既定が異なり、日本語などマルチバイト文字の
-- INSERT が "Incorrect string value" で失敗する。
-- アプリの DSN 側 (charset=utf8mb4) だけでは接続の文字セットしか決まらず、
-- カラムの文字セットは変わらない。

CREATE TABLE IF NOT EXISTS users (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    display_name  VARCHAR(100) NOT NULL,
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    bio           TEXT,
    created_at    TIMESTAMP    NOT NULL DEFAULT NOW()
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
    id         VARCHAR(64)  PRIMARY KEY,
    user_id    BIGINT       NOT NULL,
    created_at TIMESTAMP    NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMP    NOT NULL
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS posts (
    id               BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id          BIGINT      NOT NULL,
    content          TEXT        CHECK (content IS NULL OR CHAR_LENGTH(content) <= 140),
    is_repost        BOOLEAN     NOT NULL DEFAULT FALSE,
    original_post_id BIGINT,
    parent_post_id   BIGINT      DEFAULT NULL,
    created_at       TIMESTAMP   NOT NULL DEFAULT NOW()
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS follows (
    follower_id BIGINT      NOT NULL,
    followee_id BIGINT      NOT NULL,
    created_at  TIMESTAMP   NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followee_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS likes (
    user_id    BIGINT      NOT NULL,
    post_id    BIGINT      NOT NULL,
    created_at TIMESTAMP   NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS reposts (
    user_id    BIGINT      NOT NULL,
    post_id    BIGINT      NOT NULL,
    created_at TIMESTAMP   NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS footprints (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id    BIGINT      NOT NULL,
    visitor_id BIGINT      NOT NULL,
    created_at TIMESTAMP   NOT NULL DEFAULT NOW()
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notifications (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id    BIGINT      NOT NULL,
    type       VARCHAR(20) NOT NULL,
    actor_id   BIGINT      NOT NULL,
    post_id    BIGINT,
    is_read    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP   NOT NULL DEFAULT NOW()
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
