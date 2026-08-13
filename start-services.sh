#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE=/home/jovyan/work
PROJECT_DIR="${WORKSPACE}/${OPENCODE_PROJECT_DIR:-project}"
OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_DIR}/opencode.json"
OPENCODE_CONFIG_JSONC="${OPENCODE_CONFIG_DIR}/opencode.jsonc"

mkdir -p "${OPENCODE_CONFIG_DIR}"
if [[ ! -f "${OPENCODE_CONFIG_FILE}" && ! -f "${OPENCODE_CONFIG_JSONC}" ]]; then
    install -m 0644 /opt/cloudlab/opencode.json "${OPENCODE_CONFIG_FILE}"
elif ! grep -q '"kilo-anon"' "${OPENCODE_CONFIG_FILE}" "${OPENCODE_CONFIG_JSONC}" 2>/dev/null; then
    # Existing named volumes predate the default config. Merge the provider at
    # runtime without replacing a user's existing JSONC configuration.
    export OPENCODE_CONFIG_CONTENT='{"provider":{"kilo-anon":{"npm":"@ai-sdk/openai-compatible","name":"Kilo Anonymous","options":{"baseURL":"https://api.kilo.ai/api/gateway"},"models":{"kilo-auto/free":{"name":"Kilo Auto Free"}}}}}'
fi

mkdir -p "${PROJECT_DIR}"
if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
    git init --initial-branch=main "${PROJECT_DIR}"
fi
if ! grep -qxF '.env' "${PROJECT_DIR}/.gitignore" 2>/dev/null; then
    printf '\n.env\n' >> "${PROJECT_DIR}/.gitignore"
fi

cd "${PROJECT_DIR}"

opencode web \
    --hostname 0.0.0.0 \
    --port "${OPENCODE_PORT:-4096}" &
OPENCODE_PID=$!

shutdown() {
    trap - SIGINT SIGTERM EXIT
    local pids=("${OPENCODE_PID}")
    if [[ -n "${JUPYTER_PID:-}" ]]; then
        pids+=("${JUPYTER_PID}")
    fi
    kill -TERM "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
}

trap shutdown SIGINT SIGTERM EXIT

OPENCODE_URL="http://127.0.0.1:${OPENCODE_PORT:-4096}"
for attempt in {1..60}; do
    if curl --fail --silent --show-error \
        --user "${OPENCODE_SERVER_USERNAME}:${OPENCODE_SERVER_PASSWORD}" \
        "${OPENCODE_URL}/global/health" >/dev/null \
        && curl --fail --silent --show-error \
        --user "${OPENCODE_SERVER_USERNAME}:${OPENCODE_SERVER_PASSWORD}" \
        --get \
        --data-urlencode "directory=${PROJECT_DIR}" \
        "${OPENCODE_URL}/project" >/dev/null; then
        break
    fi
    if [[ "${attempt}" -eq 60 ]]; then
        echo "OpenCode did not register project ${PROJECT_DIR}" >&2
        exit 1
    fi
    sleep 1
done

start-notebook.py \
    --ServerApp.root_dir="${WORKSPACE}" &
JUPYTER_PID=$!

set +e
wait -n "${OPENCODE_PID}" "${JUPYTER_PID}"
STATUS=$?
set -e

shutdown
exit "${STATUS}"
