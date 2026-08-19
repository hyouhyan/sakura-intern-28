# インフラの構築・運用をまとめたもの。
# 各手順の背景と注意点は infra/RUNBOOK.md を参照。

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF_DIR := infra/terraform
TF     := terraform -chdir=$(TF_DIR)

# イメージのタグ。push と apply で同じ値になっている必要がある。
# push のあとにコミットを積むとずれるので、その場合は IMAGE_TAG を明示する。
IMAGE_TAG ?= $(shell git rev-parse HEAD)
export IMAGE_TAG

# レジストリのホスト名は terraform の output から取る (存在しなければ空)。
REGISTRY = $(shell $(TF) output -raw registry_fqdn 2>/dev/null)

.PHONY: help
help: ## このヘルプを表示する
	@echo "使い方: make <target>"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "まっさらから構築する場合は 'make bootstrap' から始めてください。"
	@echo "詳細と注意点は infra/RUNBOOK.md にあります。"

# ---------------------------------------------------------------- 準備

.PHONY: init
init: ## tfvars を example からコピーする (既にあれば触らない)
	@cd $(TF_DIR) && for f in secret tls; do \
	  if [ -f "$$f.auto.tfvars" ]; then \
	    echo "  $$f.auto.tfvars は既にあります"; \
	  else \
	    cp "$$f.auto.tfvars.example" "$$f.auto.tfvars"; \
	    echo "  $$f.auto.tfvars を作成しました → 中身を編集してください"; \
	  fi; \
	done
	@echo
	@echo "レジストリ名を変える場合は $(TF_DIR)/registry.auto.tfvars を作成してください:"
	@echo '  registry_name            = "..."'
	@echo '  registry_subdomain_label = "..."   # sakuracr.jp 全体で一意'

.PHONY: fmt
fmt: ## terraform fmt をかける
	@$(TF) fmt

.PHONY: validate
validate: ## 設定の妥当性を検証する
	@$(TF) validate

# ---------------------------------------------------------------- 構築

.PHONY: registry
registry: ## コンテナレジストリだけ先に作る
	@$(TF) apply -auto-approve -input=false -target=sakura_container_registry.intern
	@echo "レジストリ: $$($(TF) output -raw registry_fqdn)"

.PHONY: network
network: ## ルータだけ先に作って VIP を確定させる
	@$(TF) apply -auto-approve -input=false -target=sakura_internet.main
	@$(MAKE) --no-print-directory dns

.PHONY: dns
dns: ## 登録すべき DNS レコードを表示する
	@echo "以下の A レコードを登録してください (CDN のプロキシは通さないこと):"
	@$(TF) output dns_records

.PHONY: login
login: ## コンテナレジストリに docker login する
	@test -n "$(REGISTRY)" || { echo "レジストリが未作成です。make registry を先に実行してください" >&2; exit 1; }
	@sed -n 's/^[[:space:]]*registry_ci_user_password[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' \
	  $(TF_DIR)/secret.auto.tfvars | head -1 | docker login $(REGISTRY) -u ci --password-stdin

.PHONY: images
images: ## backend / frontend のイメージをビルドして push する
	@test -n "$(REGISTRY)" || { echo "レジストリが未作成です。make registry を先に実行してください" >&2; exit 1; }
	REGISTRY_HOST=$(REGISTRY) ./build_push_backend.sh
	@REGISTRY_HOST=$(REGISTRY) ./build_push_frontend.sh || { \
	  echo; \
	  echo "frontend の pull に失敗しました。"; \
	  echo "既定の入手元 (intern22) は資格情報が要ります。現物を持っている"; \
	  echo "レジストリがあれば FRONTEND_SOURCE_IMAGE で指定してください:"; \
	  echo "  make images FRONTEND_SOURCE_IMAGE=<既存>/intern2026-app-frontend:latest"; \
	  exit 1; \
	}

.PHONY: check-images
check-images: ## デプロイ予定のイメージがレジストリにあるか確認する
	@test -n "$(REGISTRY)" || { echo "レジストリが未作成です。make registry を先に実行してください" >&2; exit 1; }
	@missing=0; \
	for img in intern2026-app-backend intern2026-app-frontend; do \
	  if docker manifest inspect $(REGISTRY)/$$img:$(IMAGE_TAG) >/dev/null 2>&1; then \
	    printf '  %-32s ok\n' "$$img"; \
	  else \
	    printf '  %-32s 見つかりません\n' "$$img"; missing=1; \
	  fi; \
	done; \
	if [ $$missing -ne 0 ]; then \
	  echo; \
	  echo "IMAGE_TAG=$(IMAGE_TAG) のイメージがレジストリにありません。"; \
	  echo "このまま進めるとコンテナが起動せず 503 のままになります。"; \
	  echo; \
	  echo "  make images                      現在の HEAD でビルドして push する"; \
	  echo "  make <target> IMAGE_TAG=<タグ>   既にあるタグを使う"; \
	  exit 1; \
	fi

.PHONY: plan
plan: ## 変更内容を確認する
	@./terraform_plan.sh -input=false

.PHONY: apply
apply: check-images ## 全体を apply する (version の有効化は含まない)
	@./terraform_apply.sh -auto-approve -input=false

.PHONY: deploy
deploy: check-images ## version を作り直して有効化する (数分ダウンする)
	@cd $(TF_DIR) && ./redeploy.sh

.PHONY: migrate
migrate: ## DB マイグレーションを適用する
	@cd $(TF_DIR) && ./migrate.sh

.PHONY: bootstrap
bootstrap: ## まっさらから構築する (途中で DNS 登録の案内が入る)
	@$(MAKE) --no-print-directory registry
	@$(MAKE) --no-print-directory login
	@$(MAKE) --no-print-directory images
	@$(MAKE) --no-print-directory network
	@echo
	@echo "----------------------------------------------------------------"
	@echo "DNS の A レコードを登録し、反映を確認してから続きを実行してください:"
	@echo "    make apply && make deploy && make migrate && make verify"
	@echo "先に DNS を通しておかないと Let's Encrypt のレート制限を消費します。"
	@echo "----------------------------------------------------------------"

# ---------------------------------------------------------------- 確認

.PHONY: status
status: ## 現在の状態を表示する
	@echo "=== エンドポイント ==="
	@$(TF) output frontend_url
	@$(TF) output backend_url
	@echo "=== VIP / ネットワーク ==="
	@$(TF) output lb_vip
	@$(TF) output private_net
	@echo "=== ワーカーノード ==="
	@$(TF) output worker_nodes

.PHONY: verify
verify: ## エンドポイントに疎通確認する
	@vip=$$($(TF) output -raw lb_vip); \
	fe=$$($(TF) output -raw frontend_url); be=$$($(TF) output -raw backend_url); \
	fh=$${fe#*://}; fh=$${fh%%[:/]*}; bh=$${be#*://}; bh=$${bh%%[:/]*}; \
	printf 'frontend %-40s %s\n' "$$fe" \
	  "$$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve $$fh:443:$$vip $$fe/)"; \
	printf 'backend  %-40s %s (401 なら起動済み)\n' "$$be/posts" \
	  "$$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve $$bh:443:$$vip $$be/posts)"

.PHONY: lb
lb: ## LB の振り分けを確認する
	@cd $(TF_DIR) && ./check-lb.sh

# ---------------------------------------------------------------- 破棄

.PHONY: destroy
destroy: ## すべて破棄する (レジストリとイメージ、DB のデータも消える)
	@echo "レジストリとイメージ、DB のデータも消えます。VIP が変わることもあります。"
	@read -p "本当に破棄しますか? [y/N] " ans; [ "$$ans" = "y" ] || { echo "中止しました"; exit 1; }
	@cd $(TF_DIR) && ./teardown.sh
