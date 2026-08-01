#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_ROOT
readonly CONTROLLER_NAME="${SEALED_SECRETS_CONTROLLER_NAME:-sealed-secrets-controller}"
readonly CONTROLLER_NAMESPACE="${SEALED_SECRETS_CONTROLLER_NAMESPACE:-kube-system}"
readonly TARGET_NAMESPACE="simple-go-app-dev"
readonly SECRET_NAME="ghcr-pull-credentials"

required_commands=(base64 docker kubectl kubeseal kustomize)
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
if [ -z "${GHCR_USERNAME:-}" ]; then
  printf 'Set GHCR_USERNAME to the GitHub account that owns the token.\n' >&2
  exit 1
fi
if [ -z "${GHCR_IMAGE:-}" ]; then
  printf 'Set GHCR_IMAGE to a full ghcr.io image reference and immutable tag.\n' >&2
  exit 1
fi
if [[ ! "${GHCR_USERNAME}" =~ ^[A-Za-z0-9-]+$ ]]; then
  printf 'GHCR_USERNAME is not a valid GitHub username.\n' >&2
  exit 1
fi
if [[ ! "${GHCR_IMAGE}" =~ ^ghcr\.io/[a-z0-9._/-]+(:[a-f0-9]{40}|@sha256:[a-f0-9]{64})$ ]]; then
  printf 'GHCR_IMAGE must use ghcr.io and a full 40-character commit tag or sha256 digest.\n' >&2
  exit 1
fi

current_context="$(kubectl config current-context)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  printf 'Refusing to seal for context %s; expected %s.\n' \
    "${current_context}" "${EXPECTED_CONTEXT}" >&2
  exit 1
fi

read -r -s -p 'GHCR personal access token (classic): ' ghcr_token
printf '\n' >&2
if [ -z "${ghcr_token}" ]; then
  printf 'The GHCR token must not be empty.\n' >&2
  exit 1
fi
if [[ "${ghcr_token}" == *$'\n'* ]]; then
  printf 'The GHCR token must not contain a newline.\n' >&2
  exit 1
fi

umask 077
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/ghcr-pull-secret.XXXXXX")"

cleanup() {
  unset ghcr_token registry_auth
  rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT

registry_auth="$(
  printf '%s:%s' "${GHCR_USERNAME}" "${ghcr_token}" \
    | base64 \
    | tr -d '\n'
)"

docker_config="${temporary_directory}/config.json"
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' \
  "${registry_auth}" > "${docker_config}"

# This check does not require a running Docker daemon. It catches a wrong token,
# missing package permission, and a mistyped immutable image reference before sealing.
docker --config "${temporary_directory}" manifest inspect \
  "${GHCR_IMAGE}" >/dev/null

certificate_file="${temporary_directory}/sealed-secrets.pem"
kubeseal \
  --controller-name "${CONTROLLER_NAME}" \
  --controller-namespace "${CONTROLLER_NAMESPACE}" \
  --fetch-cert > "${certificate_file}"

sealed_output="${temporary_directory}/ghcr-pull-sealed-secret.yaml"
kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${TARGET_NAMESPACE}" \
  --type kubernetes.io/dockerconfigjson \
  --from-file ".dockerconfigjson=${docker_config}" \
  --dry-run=client \
  -o json \
  | kubeseal \
      --cert "${certificate_file}" \
      --scope strict \
      --format yaml \
      > "${sealed_output}"

kubeseal \
  --controller-name "${CONTROLLER_NAME}" \
  --controller-namespace "${CONTROLLER_NAMESPACE}" \
  --validate < "${sealed_output}"

overlay_directory="${REPOSITORY_ROOT}/apps/simple-go-app/overlays/dev"
install -m 0600 "${sealed_output}" \
  "${overlay_directory}/ghcr-pull-sealed-secret.yaml"

if ! awk -v expected='ghcr-pull-sealed-secret.yaml' '
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
    kustomize edit add resource ghcr-pull-sealed-secret.yaml
  )
fi

printf 'Verified %s and generated %s for context %s.\n' \
  "${GHCR_IMAGE}" "${SECRET_NAME}" "${EXPECTED_CONTEXT}"
printf '%s\n' \
  'Review the ciphertext and expected Kustomization resource additions before committing them.'
