#!/usr/bin/env bash

# Shared helpers for the OSSM 3.4 observability scripts.
# shellcheck shell=bash

load_stack_env() {
  local root="$1"
  local env_file="${root}/.env"
  local name
  local -A was_set=()
  local -A saved=()
  local vars=(
    TEMPO_TENANT_ID
    MESH_NAMESPACES
    TEMPO_NAMESPACE
    TEMPO_OBC_NAME
    TEMPO_STORAGE_SECRET
    TEMPO_S3_ENDPOINT
    APPLY_MESH_BASE
    ALLOW_OSSM2_COEXISTENCE
    ENABLE_TRACING_UI
    ENABLE_TRACING_UI_RBAC
    OPENSHIFT_CONSOLE_URL
    TRACE_TEST_URL
    E2E_REQUESTS
    TEMPO_LOCAL_PORT
  )

  [[ -f "${env_file}" ]] || return 0

  # Preserve variables explicitly supplied by the caller. This makes:
  #   APPLY_MESH_BASE=1 ./scripts/validate.sh
  # override the value stored in .env, which is normal CLI precedence.
  for name in "${vars[@]}"; do
    if [[ -v "${name}" ]]; then
      was_set["${name}"]=1
      saved["${name}"]="${!name}"
    fi
  done

  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a

  for name in "${vars[@]}"; do
    if [[ "${was_set[${name}]:-0}" == "1" ]]; then
      printf -v "${name}" '%s' "${saved[${name}]}"
      export "${name}"
    fi
  done
}

tempo_sar_allowed() {
  local user="$1"
  local verb="$2"
  local allowed

  allowed="$(
    cat <<EOF | oc create -f - -o jsonpath='{.status.allowed}'
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${user}
  resourceAttributes:
    group: tempo.grafana.com
    resource: mesh
    name: traces
    verb: ${verb}
EOF
  )"

  [[ "${allowed}" == "true" ]]
}

require_tempo_sar() {
  local label="$1"
  local user="$2"
  local verb="$3"

  if tempo_sar_allowed "${user}" "${verb}"; then
    echo "OK   ${label}: ${verb} tempo.grafana.com/mesh resourceName=traces"
  else
    echo "ERROR: ${label} is not authorized for ${verb} on Tempo tenant mesh/traces." >&2
    exit 1
  fi
}
