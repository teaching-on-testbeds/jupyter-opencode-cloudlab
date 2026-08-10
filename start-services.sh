#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE=/home/jovyan/work
PROJECT_DIR="${WORKSPACE}/${OPENCODE_PROJECT_DIR:-project}"

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
