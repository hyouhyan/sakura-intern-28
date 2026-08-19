package db

import (
	"context"
	"database/sql"
	"log"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"sakuravel/migrations"
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

	// MariaDB のデフォルト max_connections（151）に対して十分小さく、かつ
	// 現行のVMスペック（1コア/1GBメモリ、DBもAPIも同居）でも無理のない値
	// として20を選定。VM・DBのスペックを見直すタイミングで再チューニングする。
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(20)
	// 長時間張りっぱなしの古い接続が残り続けないよう、定期的に張り直す。
	db.SetConnMaxLifetime(5 * time.Minute)

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

	log.Println("database connected")
	if err := migrations.Run(context.Background(), db); err != nil {
		log.Fatalf("database migration: %v", err)
	}
	log.Println("database migrations applied")
	return db
}
