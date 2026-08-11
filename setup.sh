#!/usr/bin/env bash
set -Eeuo pipefail

# CloudLab Execute services run as the experiment user. Re-run as root before
# opening the system log or performing package and Docker administration.
if [[ ${EUID} -ne 0 ]]; then
    exec sudo /bin/bash "$0" "$@"
fi

REPO_DIR="/local/repository"
DATA_ROOT="${1:-/local}"
JUPYTER_TOKEN="${2:?CloudLab Jupyter token was not provided}"
OPENCODE_PASSWORD="${3:?CloudLab OpenCode password was not provided}"
ENV_FILE="${REPO_DIR}/.env"
LOG_FILE="/var/log/cloudlab-jupyter-opencode-setup.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[$(date -Is)] Starting CloudLab Jupyter/OpenCode setup"
echo "Repository: ${REPO_DIR}"
echo "Data root: ${DATA_ROOT}"

if [[ ! -d "${REPO_DIR}" ]]; then
    echo "ERROR: ${REPO_DIR} does not exist. This profile expects a repository-based CloudLab profile." >&2
    exit 1
fi

mkdir -p "${DATA_ROOT}"

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        return
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    . /etc/os-release
    arch="$(dpkg --print-architecture)"
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker

# Put Docker's own image/layer storage on the selected data root when possible.
# This is especially useful with CloudLab's optional temporary filesystem.
DOCKER_DATA_ROOT="${DATA_ROOT}/docker"
mkdir -p "${DOCKER_DATA_ROOT}"
if [[ ! -s /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}"
}
EOF
fi

systemctl enable docker
systemctl restart docker

JUPYTER_DATA_DIR="${DATA_ROOT}/jupyter-data"
mkdir -p "${JUPYTER_DATA_DIR}"

# The Jupyter Docker image uses UID 1000/GID 100. Give it ownership of the
# bind-mounted workspace. This directory is experiment-local and disposable.
chown -R 1000:100 "${JUPYTER_DATA_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
    umask 077

    cat > "${ENV_FILE}" <<EOF
JUPYTER_PORT=8888
OPENCODE_PORT=4096
BIND_ADDRESS=0.0.0.0
JUPYTER_DATA_DIR=${JUPYTER_DATA_DIR}
OPENCODE_PROJECT_DIR=project
JUPYTER_TOKEN=${JUPYTER_TOKEN}
OPENCODE_SERVER_USERNAME=opencode
OPENCODE_SERVER_PASSWORD=${OPENCODE_PASSWORD}
EOF
    chmod 600 "${ENV_FILE}"
else
    echo "Keeping existing ${ENV_FILE} credentials."
fi

cd "${REPO_DIR}"
docker compose up --build -d

echo
echo "[$(date -Is)] Setup complete."
echo "Credentials are shown in the CloudLab Profile Instructions."
echo "Services:"
echo "  JupyterLab: http://$(hostname -f):8888/lab"
echo "  OpenCode:   http://$(hostname -f):4096"
docker compose ps
