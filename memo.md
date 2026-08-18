### 実験条件
- 改善未実施(17-experiment) / 改善実施(16-performance) の2ブランチを比較
- シードは scale=5（`app/backend/scripts/make_seed_fixture.sh` で1回生成し、両ブランチで使い回す）
- 以降は `app/backend/scripts/run_bench_17-experiment.sh` / `run_bench_16-performance.sh` で自動計測する
  （計測用アカウント登録・フォロー・footprint用visitor作成もスクリプト内で行うので手動操作は不要）
- 下記「改善前」の最初のセクションは自動化前に手動で試し計測したもの。以後はスクリプト実行のたびに
  「#### 改善前 (17-experiment)」「#### 改善実施後 (16-performance)」として自動追記される

#### 改善前（手動での試し計測）

bench.sh, bench_concurrent.sh
- /posts_feed=following&per_page=50
  - count=100 avg=0.0007 p50=0.0006 p95=0.0010 p99=0.0015 max=0.0015
  -n=200 total=19.29s rps=10.37 avg=0.7963 p50=0.7757 p95=1.1692
- /posts?feed=latest&per_page=50
  - count=100 avg=0.0007 p50=0.0007 p95=0.0010 p99=0.0012 max=0.0012
  - n=200 total=11.61s rps=17.22 avg=0.5607 p50=0.5433 p95=0.8758
- /posts?feed=recommended&per_page=50
  - count=100 avg=0.0007 p50=0.0007 p95=0.0009 p99=0.0011 max=0.0011
  - n=200 total=13.72s rps=14.58 avg=0.5214 p50=0.4687 p95=1.1268
- /users/334/posts_per_page=50
  - count=100 avg=0.0007 p50=0.0007 p95=0.0009 p99=0.0013 max=0.0013
  - n=200 total=0.19s rps=1061.47 avg=0.0016 p50=0.0010 p95=0.0044
- 
#### 改善前 (17-experiment)

計測日時: 2026-08-19 00:48:04

| エンドポイント | 直列 (bench.sh, n=100) | 並列 (bench_concurrent.sh, n=200 c=10) | クエリ本数 |
|---|---|---|---|
