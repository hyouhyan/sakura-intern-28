#!/usr/bin/env bash
# 17-experiment / 16-performance 両方の計測エントリスクリプトから読み込まれる共通処理。
# このファイル単体では実行しない（source される前提）。

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BACKEND_DIR/../.." && pwd)"
COMPOSE_FILE="$BACKEND_DIR/docker-compose.yml"
MEMO_FILE="$REPO_ROOT/memo.md"
FIXTURE_FILE="$BACKEND_DIR/seed_fixture.sql"
COOKIE_JAR="$BACKEND_DIR/cookies.txt"

DB_USER=sakuravel
DB_PASS=password
DB_NAME=sakuravel
DB_ROOT_PASS=password

# sakuravelユーザーは(ソケット経由=localhost扱いでの)権限マッチングで
# 弾かれることがある（mysqladmin pingは通るがmysqlコマンド本体の接続は
# 拒否される、という既知のハマりどころ）。ソケット接続自体はmysqladmin ping
# で疎通確認済みなので、-hは付けずデフォルトのソケット接続のままrootを使う
# （TCP接続 -h127.0.0.1 はこの環境で接続確立に失敗したため使わない）。
mysql_root() {
  docker compose -f "$COMPOSE_FILE" exec -T db \
    mysql -u root -p"$DB_ROOT_PASS" "$@"
}

SERIAL_N=100
CONCURRENT_N=200
CONCURRENT_C=10
FOOTPRINT_VISITORS=30

BENCH_USER_ID=""
THREAD_ROOT_ID=""

log() { echo "[bench] $*" >&2; }
die() { echo "[bench] ERROR: $*" >&2; exit 1; }

# 現在のgitブランチが期待通りか確認する。
# シードデータの内容だけでなく、比較対象のアプリコード自体もブランチに
# 紐づくため、間違ったブランチで計測すると比較そのものが無意味になる。
require_branch() {
  local expected="$1" actual
  actual="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  if [[ "$actual" != "$expected" ]]; then
    die "現在のブランチは '$actual' です。'git checkout $expected' してから実行してください。"
  fi
}

# db/api を作り直す。--build で必ずそのブランチのコードを再ビルドし、
# down -v で volume を消してから up することで migrations（インデックスの
# 有無を含む）をそのブランチの内容で入れ直す。
recreate_containers() {
  log "db/api コンテナを作り直しています（クリーンな状態から起動）..."
  docker compose -f "$COMPOSE_FILE" down -v
  docker compose -f "$COMPOSE_FILE" up -d --build db api
}

wait_for_db() {
  log "DBの起動を待機中..."
  for _ in $(seq 1 60); do
    if docker compose -f "$COMPOSE_FILE" exec -T db \
        mysqladmin ping -u "$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; then
      log "DB起動確認"
      return 0
    fi
    sleep 2
  done
  die "DBが起動しませんでした"
}

wait_for_api() {
  log "APIの起動を待機中..."
  for _ in $(seq 1 60); do
    if curl -s -o /dev/null "$BASE_URL/trending" 2>/dev/null; then
      log "API起動確認"
      return 0
    fi
    sleep 2
  done
  die "APIが起動しませんでした"
}

# データのみのダンプ（seed_fixture.sql）を各ブランチのDBへ復元する。
# スキーマ（CREATE TABLE/INDEX）はブランチごとの migrations が作った
# ものをそのまま使い、データだけ差し替えることで「インデックス以外の
# 条件を完全に揃える」ことと「インデックスの差自体も測定対象に含める」
# ことを両立する。
restore_fixture() {
  local size
  size="$(wc -c < "$FIXTURE_FILE" 2>/dev/null || echo 0)"
  if [[ ! -f "$FIXTURE_FILE" ]] || [[ "$size" -lt 1000 ]]; then
    die "seed_fixture.sql が見つからないか壊れています: $FIXTURE_FILE
先に scripts/make_seed_fixture.sh を実行してください（1回だけでよい。以後は両ブランチで使い回す）。"
  fi
  log "seed_fixture.sql (${size} bytes) を復元中..."
  mysql_root "$DB_NAME" < "$FIXTURE_FILE"
}

# 計測用アカウントを新規登録する。シードユーザーはパスワードが共有されて
# いないためログインできない。following フィードを空にしないため既存
# ユーザー(id 1-10)をフォローし、footprints エンドポイントを空にしない
# ため別アカウントを複数登録して bench_user のプロフィールを訪問させる。
setup_bench_user() {
  rm -f "$COOKIE_JAR"
  log "計測用アカウント(bench_user)を登録中..."
  local resp
  resp="$(curl -s -c "$COOKIE_JAR" -X POST "$BASE_URL/register" \
    -H 'Content-Type: application/json' \
    -d '{"username":"bench_user","display_name":"bench","email":"bench@example.com","password":"benchpass123"}')"
  BENCH_USER_ID="$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || true)"
  [[ -n "$BENCH_USER_ID" ]] || die "計測用アカウントの登録に失敗しました: $resp"
  log "bench_user id=$BENCH_USER_ID"

  log "既存ユーザー(id 1-10)をフォロー中..."
  for uid in $(seq 1 10); do
    curl -s -b "$COOKIE_JAR" -X POST "$BASE_URL/users/$uid/follow" -o /dev/null || true
  done

  log "footprints計測用に visitor アカウントを ${FOOTPRINT_VISITORS} 件作成し bench_user のプロフィールを訪問..."
  for i in $(seq 1 "$FOOTPRINT_VISITORS"); do
    local jar="/tmp/bench_visitor_${i}.txt"
    curl -s -c "$jar" -X POST "$BASE_URL/register" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"bench_visitor_${i}\",\"display_name\":\"visitor${i}\",\"email\":\"bench_visitor_${i}@example.com\",\"password\":\"benchpass123\"}" \
      -o /dev/null
    curl -s -b "$jar" "$BASE_URL/profile/$BENCH_USER_ID" -o /dev/null
    rm -f "$jar"
  done
}

# スレッド計測対象として「直接の返信が最も多い投稿」を選ぶ。両ブランチとも
# 同じ seed_fixture.sql から復元しているので、この選定結果は両ブランチで
# 一致する。
pick_thread_root() {
  THREAD_ROOT_ID="$(mysql_root -N "$DB_NAME" -e \
    "SELECT parent_post_id FROM posts WHERE parent_post_id IS NOT NULL GROUP BY parent_post_id ORDER BY COUNT(*) DESC LIMIT 1;" \
    2>/dev/null | tr -d '\r')"
  [[ -n "$THREAD_ROOT_ID" ]] || die "返信付きの投稿が見つかりませんでした（シードデータを確認してください）"
  log "スレッド計測対象: post id=$THREAD_ROOT_ID"
}

# 1リクエストあたりのDB発行クエリ本数を general_log から数える。
# N+1解消の効果を最も直接的に裏付ける指標。
count_queries() {
  local url="$1"; shift
  mysql_root -e \
    "SET GLOBAL general_log='OFF'; TRUNCATE TABLE mysql.general_log; SET GLOBAL log_output='TABLE'; SET GLOBAL general_log='ON';" \
    >/dev/null 2>&1

  curl -s -o /dev/null "$url" "$@"
  sleep 1

  mysql_root -N -e \
    "SET GLOBAL general_log='OFF'; SELECT COUNT(*) FROM mysql.general_log WHERE command_type='Query';" \
    2>/dev/null | tr -d '\r' | tail -1
}

write_memo_header() {
  local label="$1"
  {
    echo ""
    echo "#### ${label}"
    echo ""
    echo "計測日時: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "| エンドポイント | 直列 (bench.sh, n=${SERIAL_N}) | 並列 (bench_concurrent.sh, n=${CONCURRENT_N} c=${CONCURRENT_C}) | クエリ本数 |"
    echo "|---|---|---|---|"
  } >> "$MEMO_FILE"
}

write_memo_row() {
  local name="$1" serial="$2" concurrent="$3" queries="$4"
  echo "| $name | $serial | $concurrent | $queries |" >> "$MEMO_FILE"
}

# 対象11エンドポイント + recommended（初回/定常状態を分けて計測）を
# 順に計測し、memo.md に1行ずつ追記する。1エンドポイントの失敗で全体を
# 止めないよう、ループ内ではエラーで即終了しない。
run_all_endpoints() {
  local prev_opts
  prev_opts="$(set +o | grep errexit)"
  set +e

  local auth=(-b "$COOKIE_JAR")
  local defs=(
    "GET /posts?feed=following|1|${BASE_URL}/posts?feed=following&per_page=50"
    "GET /posts?feed=latest|1|${BASE_URL}/posts?feed=latest&per_page=50"
    "GET /users/{id}/posts|0|${BASE_URL}/users/1/posts?per_page=50"
    "GET /posts/{id}/thread|0|${BASE_URL}/posts/${THREAD_ROOT_ID}/thread"
    "GET /search?type=posts|0|${BASE_URL}/search?q=a&type=posts&per_page=50"
    "GET /search?type=users|0|${BASE_URL}/search?q=user&type=users&per_page=50"
    "GET /notifications|1|${BASE_URL}/notifications?per_page=50"
    "GET /me/footprints|1|${BASE_URL}/me/footprints?per_page=50"
    "GET /trending|0|${BASE_URL}/trending"
    "GET /users/{id}/followers|0|${BASE_URL}/users/1/followers"
    "GET /users/{id}/following|0|${BASE_URL}/users/1/following"
    "GET /profile/{id}|0|${BASE_URL}/profile/1"
  )

  for def in "${defs[@]}"; do
    IFS='|' read -r label need_auth url <<< "$def"
    local extra=()
    [[ "$need_auth" == "1" ]] && extra=("${auth[@]}")
    log "計測中: $label"
    local serial concurrent queries
    serial="$("$BACKEND_DIR/bench.sh" "$url" "${extra[@]}")"
    concurrent="$("$BACKEND_DIR/bench_concurrent.sh" "$url" "${extra[@]}")"
    queries="$(count_queries "$url" "${extra[@]}")"
    write_memo_row "$label" "$serial" "$concurrent" "$queries"
  done

  # recommended フィードは集計キャッシュ（30秒TTL、16-performanceのみ）が
  # あるため、初回(キャッシュミス)を単発で分けて計測してからbench系を回す。
  log "計測中: GET /posts?feed=recommended"
  local rec_url="${BASE_URL}/posts?feed=recommended&per_page=50"
  local first serial concurrent queries
  first="$(curl -s -o /dev/null -w '%{time_total}' "$rec_url" "${auth[@]}")"
  serial="$("$BACKEND_DIR/bench.sh" "$rec_url" "${auth[@]}")"
  concurrent="$("$BACKEND_DIR/bench_concurrent.sh" "$rec_url" "${auth[@]}")"
  queries="$(count_queries "$rec_url" "${auth[@]}")"
  write_memo_row "GET /posts?feed=recommended（初回=${first}s）" "$serial" "$concurrent" "$queries"

  eval "$prev_opts"
}
