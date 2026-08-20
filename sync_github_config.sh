#!/usr/bin/env bash
set -euo pipefail

repo="${GH_REPO:-}"
dry_run=false

usage() {
  echo "Usage: $0 [--repo OWNER/REPO] [--dry-run]"
}

while (($# > 0)); do
  case "$1" in
    --repo)
      repo="${2:?--repo requires OWNER/REPO}"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main_secrets="$root_dir/infra/terraform/secret.auto.tfvars"
environment_vars="$root_dir/infra/terraform/environment.auto.tfvars"
bootstrap_secrets="$root_dir/infra/terraform-bootstrap/secret.auto.tfvars"

for file in "$root_dir/.env" "$main_secrets" "$environment_vars" "$bootstrap_secrets"; do
  if [[ ! -f "$file" ]]; then
    echo "Required local config is missing: ${file#"$root_dir/"}" >&2
    exit 1
  fi
done

for command_name in gh terraform; do
  if ! command -v "$command_name" >/dev/null; then
    echo "Required command is not installed: $command_name" >&2
    exit 1
  fi
done

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

gh auth status >/dev/null

# .env is a local, trusted shell-format file containing Sakura API credentials.
set -a
# shellcheck disable=SC1091
source "$root_dir/.env"
set +a

read_tfvar() {
  local name="$1"
  local file="$2"
  awk -v wanted="$name" -F= '
    $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file"
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == *'<'* || "$value" == *'>'* ]]
}

require_value() {
  local name="$1"
  local value="$2"
  if is_placeholder "$value"; then
    echo "Local value is missing or still a placeholder: $name" >&2
    exit 1
  fi
}

set_secret() {
  local name="$1"
  local value="$2"
  if is_placeholder "$value"; then
    echo "skipped  secret $name (local value is missing or a placeholder)"
    return
  fi
  if $dry_run; then
    echo "secret   $name"
  else
    printf '%s' "$value" | gh secret set "$name" --repo "$repo"
    echo "updated  secret $name"
  fi
}

set_variable() {
  local name="$1"
  local value="$2"
  require_value "$name" "$value"
  if $dry_run; then
    echo "variable $name=$value"
  else
    gh variable set "$name" --repo "$repo" --body "$value"
    echo "updated  variable $name=$value"
  fi
}

sakura_access_token="${SAKURA_ACCESS_TOKEN:-}"
sakura_access_token_secret="${SAKURA_ACCESS_TOKEN_SECRET:-}"
db_password="$(read_tfvar db_password "$main_secrets")"
service_principal_id="$(read_tfvar service_principal_id "$main_secrets")"
frontend_host="$(read_tfvar frontend_host "$main_secrets")"
backend_host="$(read_tfvar backend_host "$main_secrets")"
registry_apprun_password="$(read_tfvar registry_apprun_user_password "$main_secrets")"
registry_ci_password="$(read_tfvar registry_ci_user_password "$bootstrap_secrets")"

zone="$(read_tfvar zone "$environment_vars")"
cluster_name="$(read_tfvar cluster_name "$environment_vars")"
cluster_email="$(read_tfvar cluster_lets_encrypt_email "$environment_vars")"
registry_name="$(read_tfvar registry_name "$environment_vars")"
enable_tls="$(read_tfvar enable_tls "$environment_vars")"

if [[ "$enable_tls" != true && "$enable_tls" != false ]]; then
  echo "enable_tls must be true or false in infra/terraform/environment.auto.tfvars" >&2
  exit 1
fi

tfstate_access_key="$(terraform -chdir="$root_dir/infra/terraform-bootstrap" output -raw access_key)"
tfstate_secret_key="$(terraform -chdir="$root_dir/infra/terraform-bootstrap" output -raw secret_key)"
tfstate_bucket="$(terraform -chdir="$root_dir/infra/terraform-bootstrap" output -raw bucket_name)"
registry_subdomain="$(terraform -chdir="$root_dir/infra/terraform-bootstrap" output -raw registry_subdomain_label)"

echo "Repository: $repo"
echo "Mode: $($dry_run && echo dry-run || echo update)"

set_secret sakura_access_token "$sakura_access_token"
set_secret sakura_access_token_secret "$sakura_access_token_secret"
set_secret tfstate_access_key_id "$tfstate_access_key"
set_secret tfstate_secret_access_key "$tfstate_secret_key"
set_secret tf_var_db_password "$db_password"
set_secret tf_var_registry_apprun_user_password "$registry_apprun_password"
set_secret registry_subdomain "$registry_subdomain"
set_secret registry_ci_user_password "$registry_ci_password"

set_variable enable_tls "$enable_tls"
set_variable tfstate_bucket "$tfstate_bucket"
set_variable tf_var_zone "$zone"
set_variable tf_var_cluster_name "$cluster_name"
set_variable tf_var_cluster_lets_encrypt_email "$cluster_email"
set_variable tf_var_registry_name "$registry_name"
set_variable TF_VAR_service_principal_id "$service_principal_id"
set_variable TF_VAR_frontend_host "$frontend_host"
set_variable TF_VAR_backend_host "$backend_host"
set_variable registry_apprun_user_name apprun

echo "GitHub Actions configuration is synchronized."
