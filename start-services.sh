#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE=/home/jovyan/work
PROJECT_GIT_URL="${OPENCODE_PROJECT_GIT_URL:-}"
PROJECT_DIR="${WORKSPACE}/${OPENCODE_PROJECT_DIR:-project}"
export CODE_WORKINGDIR="${PROJECT_DIR}"
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
shopt -s dotglob nullglob
project_entries=("${PROJECT_DIR}"/*)
if [[ -n "${PROJECT_GIT_URL}" && ${#project_entries[@]} -eq 0 ]]; then
    git clone "${PROJECT_GIT_URL}" "${PROJECT_DIR}"
elif [[ -n "${PROJECT_GIT_URL}" && ! -d "${PROJECT_DIR}/.git" ]]; then
    echo "Project directory is not empty and is not a Git repository: ${PROJECT_DIR}" >&2
    exit 1
elif [[ ! -d "${PROJECT_DIR}/.git" ]]; then
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

start-notebook.py \
    --ServerApp.root_dir="${WORKSPACE}" &
JUPYTER_PID=$!

shutdown() {
    trap - SIGINT SIGTERM EXIT
    kill -TERM "${OPENCODE_PID}" "${JUPYTER_PID}" 2>/dev/null || true
    wait "${OPENCODE_PID}" "${JUPYTER_PID}" 2>/dev/null || true
}

trap shutdown SIGINT SIGTERM EXIT

set +e
wait -n "${OPENCODE_PID}" "${JUPYTER_PID}"
STATUS=$?
set -e

shutdown
exit "${STATUS}"
