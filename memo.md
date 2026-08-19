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

#### 改善前 (17-experiment)

計測日時: 2026-08-19 01:06:04

| エンドポイント | 直列 (bench.sh, n=20) | 並列 (bench_concurrent.sh, n=30 c=10) | クエリ本数 |
|---|---|---|---|
| GET /posts?feed=following | count=20 avg=5.2746 p50=5.3113 p95=6.4010 p99=6.4010 max=6.4010 | n=30 total=171.91s rps=0.17 avg=50.6854 p50=50.9586 p95=54.4361 | 1 |
| GET /posts?feed=latest | count=20 avg=4.7665 p50=4.7473 p95=4.9402 p99=4.9402 max=4.9402 | n=30 total=161.83s rps=0.19 avg=48.1883 p50=48.0580 p95=52.0475 | 2 |
| GET /users/{id}/posts | count=20 avg=1.7956 p50=1.7739 p95=1.9728 p99=1.9728 max=1.9728 | n=30 total=64.29s rps=0.47 avg=18.5433 p50=18.5964 p95=20.6775 | 1 |
| GET /posts/{id}/thread | count=20 avg=0.5542 p50=0.5472 p95=0.6504 p99=0.6504 max=0.6504 | n=30 total=19.67s rps=1.52 avg=5.1206 p50=5.1935 p95=5.7825 | 1 |
| GET /search?type=posts | count=20 avg=0.0503 p50=0.0498 p95=0.0589 p99=0.0589 max=0.0589 | n=30 total=1.60s rps=18.76 avg=0.4703 p50=0.4238 p95=1.0283 | 1 |
| GET /search?type=users | count=20 avg=1.4841 p50=1.4786 p95=1.7681 p99=1.7681 max=1.7681 | n=30 total=49.97s rps=0.60 avg=15.2341 p50=15.3132 p95=16.6050 | 1 |
| GET /notifications | count=20 avg=0.9503 p50=0.9514 p95=1.0683 p99=1.0683 max=1.0683 | n=30 total=32.44s rps=0.92 avg=9.3736 p50=9.3580 p95=10.4458 | 1 |
| GET /me/footprints | count=20 avg=0.9211 p50=0.9162 p95=0.9761 p99=0.9761 max=0.9761 | n=30 total=31.29s rps=0.96 avg=9.0686 p50=9.1641 p95=9.9807 | 1 |
| GET /trending | count=20 avg=2.6164 p50=2.6047 p95=2.7866 p99=2.7866 max=2.7866 | n=30 total=86.72s rps=0.35 avg=26.0160 p50=25.9518 p95=33.3487 | 2 |
| GET /users/{id}/followers | count=20 avg=3.2328 p50=3.1967 p95=3.6182 p99=3.6182 max=3.6182 | n=30 total=119.14s rps=0.25 avg=34.4054 p50=34.1497 p95=37.9584 | 1 |
| GET /users/{id}/following | count=20 avg=3.0542 p50=3.0481 p95=3.4436 p99=3.4436 max=3.4436 | n=30 total=92.77s rps=0.32 avg=28.2057 p50=28.3125 p95=30.3056 | 1 |
| GET /profile/{id} | count=20 avg=0.0289 p50=0.0286 p95=0.0345 p99=0.0345 max=0.0345 | n=30 total=0.96s rps=31.10 avg=0.2894 p50=0.2842 p95=0.5221 | 1 |
