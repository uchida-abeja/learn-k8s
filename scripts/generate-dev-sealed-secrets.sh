#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_ROOT
readonly CONTROLLER_NAME="${SEALED_SECRETS_CONTROLLER_NAME:-sealed-secrets-controller}"
readonly CONTROLLER_NAMESPACE="${SEALED_SECRETS_CONTROLLER_NAMESPACE:-kube-system}"

required_commands=(kubectl kubeseal openssl kustomize)
for command_name in "${required_commands[@]}"
do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done

if [ -z "${EXPECTED_CONTEXT:-}" ]; then
  printf 'Set EXPECTED_CONTEXT to the target kubectl context.\n' >&2
  exit 1
fi

current_context="$(kubectl config current-context)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  printf 'Refusing to seal for context %s; expected %s.\n' \
    "${current_context}" "${EXPECTED_CONTEXT}" >&2
  exit 1
fi

simple_app_directory="${REPOSITORY_ROOT}/apps/simple-go-app/overlays/dev"
data_pipeline_directory="${REPOSITORY_ROOT}/apps/data-pipeline/overlays/dev"
managed_outputs=(
  "${simple_app_directory}/simple-go-app-sealed-secret.yaml"
  "${data_pipeline_directory}/data-pipeline-minio-sealed-secret.yaml"
  "${data_pipeline_directory}/data-pipeline-airflow-sealed-secret.yaml"
  "${data_pipeline_directory}/airflow-runtime-sealed-secret.yaml"
  "${data_pipeline_directory}/airflow-metadata-sealed-secret.yaml"
)

if [ "${CONFIRM_FRESH_CLUSTER:-}" != "${EXPECTED_CONTEXT}" ]; then
  printf 'This bootstrap is only for a fresh cluster with no reused PVCs.\n' >&2
  printf 'Set CONFIRM_FRESH_CLUSTER=%s after verifying that condition.\n' \
    "${EXPECTED_CONTEXT}" >&2
  exit 1
fi

if [ "${OVERWRITE_SEALED_SECRETS:-0}" != "1" ]; then
  for managed_output in "${managed_outputs[@]}"
  do
    if [ -e "${managed_output}" ]; then
      printf 'Refusing to rotate existing credentials: %s\n' \
        "${managed_output}" >&2
      printf 'Do not overwrite credentials for a cluster with existing data.\n' >&2
      printf 'See README.md for the fresh-cluster regeneration guard.\n' >&2
      exit 1
    fi
  done
fi

umask 077
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/dev-sealed-secrets.XXXXXX")"

cleanup() {
  unset \
    minio_password airflow_admin_password \
    fernet_key webserver_secret_key \
    redis_password redis_connection \
    postgres_password postgres_connection
  rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT

certificate_file="${temporary_directory}/sealed-secrets.pem"
kubeseal \
  --controller-name "${CONTROLLER_NAME}" \
  --controller-namespace "${CONTROLLER_NAMESPACE}" \
  --fetch-cert > "${certificate_file}"

read_with_default() {
  local prompt="$1"
  local default_value="$2"
  local result

  read -r -p "${prompt} [${default_value}]: " result
  printf '%s' "${result:-${default_value}}"
}

read_secret() {
  local prompt="$1"
  local first_value
  local second_value

  read -r -s -p "${prompt}: " first_value
  printf '\n' >&2
  read -r -s -p "Confirm ${prompt}: " second_value
  printf '\n' >&2

  if [ -z "${first_value}" ]; then
    printf '%s must not be empty.\n' "${prompt}" >&2
    return 1
  fi
  if [ "${first_value}" != "${second_value}" ]; then
    printf '%s values did not match.\n' "${prompt}" >&2
    return 1
  fi
  if [[ "${first_value}" == *$'\n'* ]]; then
    printf '%s must not contain a newline.\n' "${prompt}" >&2
    return 1
  fi

  printf '%s' "${first_value}"
}

minio_username="$(read_with_default 'MinIO username' 'minioadmin')"
minio_password="$(read_secret 'MinIO password')"
airflow_admin_username="$(read_with_default 'Airflow admin username' 'admin')"
airflow_admin_password="$(read_secret 'Airflow admin password')"

if [[ "${minio_username}" == *$'\n'* || "${airflow_admin_username}" == *$'\n'* ]]; then
  printf 'Usernames must not contain a newline.\n' >&2
  exit 1
fi
if [ "${#minio_username}" -lt 3 ]; then
  printf 'MinIO username must be at least 3 characters.\n' >&2
  exit 1
fi
if [ "${#minio_password}" -lt 8 ]; then
  printf 'MinIO password must be at least 8 characters.\n' >&2
  exit 1
fi
if [ "${#airflow_admin_password}" -lt 8 ]; then
  printf 'Airflow admin password must be at least 8 characters.\n' >&2
  exit 1
fi

# Fernet requires 32 random bytes encoded with URL-safe base64.
fernet_key="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n')"
webserver_secret_key="$(openssl rand -hex 32)"
redis_password="$(openssl rand -hex 24)"
redis_connection="redis://:${redis_password}@airflow-redis:6379/0"
postgres_password="$(openssl rand -hex 24)"
postgres_connection="postgresql://postgres:${postgres_password}@airflow-postgresql:5432/postgres?sslmode=disable"

seal_env_file() {
  local namespace="$1"
  local secret_name="$2"
  local env_file="$3"
  local output_file="$4"

  kubectl create secret generic "${secret_name}" \
    --namespace "${namespace}" \
    --from-env-file "${env_file}" \
    --dry-run=client \
    -o json \
    | kubeseal \
        --cert "${certificate_file}" \
        --scope strict \
        --format yaml \
        > "${output_file}"

  kubeseal \
    --controller-name "${CONTROLLER_NAME}" \
    --controller-namespace "${CONTROLLER_NAMESPACE}" \
    --validate < "${output_file}"
}

simple_app_env="${temporary_directory}/simple-go-app.env"
minio_env="${temporary_directory}/minio.env"
airflow_credentials_env="${temporary_directory}/airflow-credentials.env"
airflow_runtime_env="${temporary_directory}/airflow-runtime.env"
airflow_metadata_env="${temporary_directory}/airflow-metadata.env"

printf '%s\n' \
  'minio-endpoint=minio.data-pipeline-dev.svc.cluster.local:9000' \
  "minio-access-key=${minio_username}" \
  "minio-secret-key=${minio_password}" \
  > "${simple_app_env}"

printf '%s\n' \
  "rootUser=${minio_username}" \
  "rootPassword=${minio_password}" \
  > "${minio_env}"

printf '%s\n' \
  "admin-username=${airflow_admin_username}" \
  "admin-password=${airflow_admin_password}" \
  > "${airflow_credentials_env}"

printf '%s\n' \
  "fernet-key=${fernet_key}" \
  "webserver-secret-key=${webserver_secret_key}" \
  "password=${redis_password}" \
  "connection=${redis_connection}" \
  > "${airflow_runtime_env}"

printf '%s\n' \
  "connection=${postgres_connection}" \
  "postgres-password=${postgres_password}" \
  > "${airflow_metadata_env}"

simple_app_output="${temporary_directory}/simple-go-app-sealed-secret.yaml"
minio_output="${temporary_directory}/data-pipeline-minio-sealed-secret.yaml"
airflow_credentials_output="${temporary_directory}/data-pipeline-airflow-sealed-secret.yaml"
airflow_runtime_output="${temporary_directory}/airflow-runtime-sealed-secret.yaml"
airflow_metadata_output="${temporary_directory}/airflow-metadata-sealed-secret.yaml"

seal_env_file \
  simple-go-app-dev simple-go-app-secrets \
  "${simple_app_env}" "${simple_app_output}"
seal_env_file \
  data-pipeline-dev minio-credentials \
  "${minio_env}" "${minio_output}"
seal_env_file \
  data-pipeline-dev airflow-credentials \
  "${airflow_credentials_env}" "${airflow_credentials_output}"
seal_env_file \
  data-pipeline-dev airflow-runtime-secrets \
  "${airflow_runtime_env}" "${airflow_runtime_output}"
seal_env_file \
  data-pipeline-dev airflow-metadata \
  "${airflow_metadata_env}" "${airflow_metadata_output}"

install -m 0600 "${simple_app_output}" \
  "${simple_app_directory}/simple-go-app-sealed-secret.yaml"
install -m 0600 "${minio_output}" \
  "${data_pipeline_directory}/data-pipeline-minio-sealed-secret.yaml"
install -m 0600 "${airflow_credentials_output}" \
  "${data_pipeline_directory}/data-pipeline-airflow-sealed-secret.yaml"
install -m 0600 "${airflow_runtime_output}" \
  "${data_pipeline_directory}/airflow-runtime-sealed-secret.yaml"
install -m 0600 "${airflow_metadata_output}" \
  "${data_pipeline_directory}/airflow-metadata-sealed-secret.yaml"

add_resource_if_missing() {
  local overlay_directory="$1"
  local resource_file="$2"

  if ! awk -v expected="${resource_file}" '
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == expected) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${overlay_directory}/kustomization.yaml"; then
    (
      cd -- "${overlay_directory}"
      kustomize edit add resource "${resource_file}"
    )
  fi
}

add_resource_if_missing \
  "${simple_app_directory}" simple-go-app-sealed-secret.yaml
add_resource_if_missing \
  "${data_pipeline_directory}" data-pipeline-minio-sealed-secret.yaml
add_resource_if_missing \
  "${data_pipeline_directory}" data-pipeline-airflow-sealed-secret.yaml
add_resource_if_missing \
  "${data_pipeline_directory}" airflow-runtime-sealed-secret.yaml
add_resource_if_missing \
  "${data_pipeline_directory}" airflow-metadata-sealed-secret.yaml

printf 'Generated and validated dev SealedSecrets for context %s.\n' \
  "${EXPECTED_CONTEXT}"
printf '%s\n' \
  'Review the ciphertext and expected Kustomization resource additions before committing them.'
