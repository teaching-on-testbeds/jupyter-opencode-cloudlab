#!/usr/bin/env bash
set -Eeuo pipefail

# CloudLab Execute services run as the experiment user. Re-run as root before
# opening the system log or performing package and Docker administration.
if [[ ${EUID} -ne 0 ]]; then
    exec sudo /bin/bash "$0" "$@"
fi

REPO_DIR="/local/repository"
DATA_ROOT="${1:-/local}"
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

configure_host_access() {
    local ssh_dir="/etc/cloudlab-opencode-ssh"
    local private_key="${ssh_dir}/id_ed25519"
    local known_hosts="${ssh_dir}/known_hosts"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openssh-server sudo

    if ! id opencode >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash opencode
    else
        usermod --home /home/opencode --shell /bin/bash opencode
    fi

    install -d -m 0755 -o opencode -g opencode /home/opencode
    install -d -m 0700 -o opencode -g opencode /home/opencode/.ssh
    install -d -m 0755 "${ssh_dir}"
    if [[ ! -f "${private_key}" ]]; then
        ssh-keygen -q -t ed25519 -N "" -C "cloudlab-opencode-host-access" -f "${private_key}"
    fi

    install -m 0600 -o opencode -g opencode \
        "${private_key}.pub" /home/opencode/.ssh/authorized_keys

    cat > /etc/sudoers.d/opencode <<'EOF'
opencode ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 0440 /etc/sudoers.d/opencode
    visudo -cf /etc/sudoers.d/opencode

    : > "${known_hosts}"
    for host_key in /etc/ssh/ssh_host_*_key.pub; do
        read -r key_type key_value _ < "${host_key}"
        printf 'host.docker.internal %s %s\n' "${key_type}" "${key_value}" >> "${known_hosts}"
    done
    chmod 0644 "${known_hosts}"

    # The container runs as UID 1000 and needs read access to this key.
    chown 1000:100 "${private_key}"
    chmod 0600 "${private_key}"

    systemctl enable --now ssh
}

configure_host_access

# Put Docker's image, layer, and named-volume storage on the selected data
# root. The CloudLab default is /mydata.
DOCKER_DATA_ROOT="${DATA_ROOT}/docker"
mkdir -p "${DOCKER_DATA_ROOT}"
if [[ ! -s /etc/docker/daemon.json ]] || ! grep -q '"data-root"' /etc/docker/daemon.json; then
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}"
}
EOF
elif ! grep -q "\"data-root\": \"${DOCKER_DATA_ROOT}\"" /etc/docker/daemon.json; then
    echo "ERROR: /etc/docker/daemon.json uses a different Docker data root." >&2
    echo "       Expected Docker storage under ${DOCKER_DATA_ROOT}." >&2
    exit 1
fi

systemctl enable docker
systemctl restart docker

JUPYTER_DATA_DIR="${DATA_ROOT}/jupyter-data"
mkdir -p "${JUPYTER_DATA_DIR}"

# The Jupyter Docker image uses UID 1000/GID 100. Give it ownership of the
# bind-mounted workspace. This directory is experiment-local and disposable.
chown -R 1000:100 "${JUPYTER_DATA_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} was not created by the CloudLab startup service." >&2
    exit 1
fi

echo "Using credentials written by the CloudLab startup service."

cd "${REPO_DIR}"
docker compose up --build -d
docker compose exec -T jupyter \
    ssh -i /home/jovyan/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes \
    -o UpdateHostKeys=no \
    opencode@host.docker.internal "sudo -n true"

echo
echo "[$(date -Is)] Setup complete."
echo "Credentials are shown in the CloudLab Profile Instructions."
echo "Services:"
echo "  JupyterLab: http://$(hostname -f):8888/lab"
echo "  OpenCode:   http://$(hostname -f):4096"
docker compose ps
