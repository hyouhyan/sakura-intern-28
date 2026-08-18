#!/usr/bin/env bash
# 初回に1回だけ実行する: シードデータを生成し、17-experiment / 16-performance
# 両方の計測スクリプトから使い回す seed_fixture.sql (データのみのダンプ) を作る。
#
# データのみ（--no-create-info）でダンプするのがポイント。CREATE TABLE/INDEX
# まで含めてダンプすると、復元時にそのブランチのmigrationsが作ったスキーマ
# （インデックスの有無の差）を上書きしてしまい、正しい比較にならない。
#
# 17-experiment ブランチで実行すること（scale等のシード条件は
# 16-performance側でも同じ内容を使い回すため、片方だけで作ればよい）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bench_lib.sh"

require_branch "17-experiment"

SCALE="${SCALE:-5}"
GO_IMAGE="golang:1.25-alpine3.24"

log "クリーンな状態でDBのみ起動..."
docker compose -f "$COMPOSE_FILE" down -v
docker compose -f "$COMPOSE_FILE" up -d db
wait_for_db

log "シード投入中 (scale=$SCALE)。ホストにGoが無くても実行できるよう使い捨てコンテナで実行します..."
docker run --rm \
  --network app-network \
  -v "$BACKEND_DIR":/app -w /app \
  -e DATABASE_URL="sakuravel:password@tcp(db:3306)/sakuravel?parseTime=true&charset=utf8mb4" \
  "$GO_IMAGE" \
  go run ./seed -scale "$SCALE"

log "データのみをダンプ中..."
docker compose -f "$COMPOSE_FILE" exec -T db \
  mysqldump --no-create-info --skip-triggers --single-transaction \
  -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$FIXTURE_FILE"

size="$(wc -c < "$FIXTURE_FILE")"
[[ "$size" -gt 1000 ]] || die "ダンプが小さすぎます（$size bytes）。シード投入に失敗していないか確認してください。"

log "生成完了: $FIXTURE_FILE (${size} bytes)"
log "このDBはこの後 down -v で消えるので保持不要。各ブランチの run_bench_*.sh を実行してください。"
