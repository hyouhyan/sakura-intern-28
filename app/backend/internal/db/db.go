package db

import (
	"database/sql"
	"log"
	"os"
	"strconv"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// 接続プールの既定値。
// インスタンスを増やす場合、DBへの接続数の合計は
// インスタンス数 × maxOpenConns になる。DB側の max_connections を
// 超えないよう、スケールアウト時は DB_MAX_OPEN_CONNS で調整する。
const (
	defaultMaxOpenConns = 20
	defaultMaxIdleConns = 10
	connMaxLifetime     = 5 * time.Minute
)

func New() *sql.DB {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatalf("DATABASE_URL is not set")
	}

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}

	maxOpen := envInt("DB_MAX_OPEN_CONNS", defaultMaxOpenConns)
	maxIdle := envInt("DB_MAX_IDLE_CONNS", defaultMaxIdleConns)
	if maxIdle > maxOpen {
		maxIdle = maxOpen
	}
	db.SetMaxOpenConns(maxOpen)
	db.SetMaxIdleConns(maxIdle)
	// ロードバランサやDB側に黙って切られた接続を掴み続けないよう寿命を設ける
	db.SetConnMaxLifetime(connMaxLifetime)

	for i := 0; i < 10; i++ {
		if err = db.Ping(); err == nil {
			break
		}
		log.Printf("waiting for db... (%d/10)", i+1)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("db ping: %v", err)
	}

	log.Printf("database connected (max_open=%d max_idle=%d)", maxOpen, maxIdle)
	return db
}

// envInt は環境変数を正の整数として読む。未設定や不正な値なら fallback を返す。
func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 {
		log.Printf("%s=%q is invalid, using %d", key, v, fallback)
		return fallback
	}
	return n
}
