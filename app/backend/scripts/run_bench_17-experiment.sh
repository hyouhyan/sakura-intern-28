#!/usr/bin/env bash
# 改善前(17-experiment)ブランチで実行する計測スクリプト。
# 'git checkout 17-experiment' した状態で実行すること。
#
# 事前に scripts/make_seed_fixture.sh を1回実行して seed_fixture.sql を
# 作っておく必要がある（このスクリプトはそれを復元するだけで、シードの
# 再生成は行わない）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bench_lib.sh"

require_branch "17-experiment"

log "=== 改善前 (17-experiment) の計測を開始 ==="
recreate_containers
wait_for_db
restore_fixture
wait_for_api
setup_bench_user
pick_thread_root

write_memo_header "改善前 (17-experiment)"
run_all_endpoints

log "完了。結果は $MEMO_FILE に追記しました。"
log "db/apiコンテナは調査用に起動したままにしています。停止する場合: docker compose -f $COMPOSE_FILE down"
