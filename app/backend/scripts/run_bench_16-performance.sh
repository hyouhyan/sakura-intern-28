#!/usr/bin/env bash
# 改善実施後(16-performance)ブランチで実行する計測スクリプト。
# 'git checkout 16-performance' した状態で実行すること。
#
# 事前に 17-experiment ブランチで scripts/make_seed_fixture.sh を1回実行して
# seed_fixture.sql を作っておく必要がある（このスクリプトはそれを復元する
# だけで、シードの再生成は行わない）。scripts/ 以下のファイルはgit管理外の
# ためブランチを切り替えても残る想定。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bench_lib.sh"

require_branch "16-performance"

log "=== 改善実施後 (16-performance) の計測を開始 ==="
recreate_containers
wait_for_db
restore_fixture
wait_for_api
setup_bench_user
pick_thread_root

write_memo_header "改善実施後 (16-performance)"
run_all_endpoints

log "完了。結果は $MEMO_FILE に追記しました。"
log "db/apiコンテナは調査用に起動したままにしています。停止する場合: docker compose -f $COMPOSE_FILE down"
