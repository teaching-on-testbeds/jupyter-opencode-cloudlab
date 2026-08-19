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
GPU_MODE="${GPU_MODE:-}"
ALLOW_HOST_NVIDIA_DRIVER_INSTALL="${ALLOW_HOST_NVIDIA_DRIVER_INSTALL:-}"
ACCELERATION_MODE="cpu"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[$(date -Is)] Starting CloudLab Jupyter/OpenCode setup"
echo "Repository: ${REPO_DIR}"
echo "Data root: ${DATA_ROOT}"

if [[ ! -d "${REPO_DIR}" ]]; then
    echo "ERROR: ${REPO_DIR} does not exist. This profile expects a repository-based CloudLab profile." >&2
    exit 1
fi

read_env_option() {
    local option="$1"
    local key value

    [[ -f "${ENV_FILE}" ]] || return 0
    while IFS='=' read -r key value; do
        if [[ "${key}" == "${option}" ]]; then
            printf '%s' "${value}"
            return 0
        fi
    done < "${ENV_FILE}"
}

GPU_MODE="${GPU_MODE:-$(read_env_option GPU_MODE)}"
GPU_MODE="${GPU_MODE:-auto}"
ALLOW_HOST_NVIDIA_DRIVER_INSTALL="${ALLOW_HOST_NVIDIA_DRIVER_INSTALL:-$(read_env_option ALLOW_HOST_NVIDIA_DRIVER_INSTALL)}"
ALLOW_HOST_NVIDIA_DRIVER_INSTALL="${ALLOW_HOST_NVIDIA_DRIVER_INSTALL:-1}"

case "${GPU_MODE}" in
    auto|cpu|gpu)
        ;;
    *)
        echo "ERROR: GPU_MODE must be auto, cpu, or gpu." >&2
        exit 1
        ;;
esac

if [[ "${ALLOW_HOST_NVIDIA_DRIVER_INSTALL}" != "0" && "${ALLOW_HOST_NVIDIA_DRIVER_INSTALL}" != "1" ]]; then
    echo "ERROR: ALLOW_HOST_NVIDIA_DRIVER_INSTALL must be 0 or 1." >&2
    exit 1
fi

if [[ "$(dpkg --print-architecture 2>/dev/null || true)" != "amd64" ]]; then
    echo "ERROR: The CUDA container image requires an amd64 host." >&2
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

has_nvidia_hardware() {
    local device
    local devices=(/sys/bus/pci/devices/*)

    for device in "${devices[@]}"; do
        [[ -r "${device}/vendor" ]] || continue
        if [[ "$(<"${device}/vendor")" == "0x10de" ]]; then
            return 0
        fi
    done
    return 1
}

has_nvidia_driver() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

wait_for_nvidia_driver() {
    local attempt

    for attempt in {1..12}; do
        if has_nvidia_driver; then
            return 0
        fi
        echo "Waiting for the NVIDIA driver (attempt ${attempt}/12)."
        sleep 5
    done
    return 1
}

install_nvidia_driver() {
    local kernel_headers="linux-headers-$(uname -r)"
    local driver_package driver_suffix utils_package kernel_module

    if [[ "${ALLOW_HOST_NVIDIA_DRIVER_INSTALL}" != "1" ]]; then
        echo "NVIDIA hardware detected, but automatic host driver installation is disabled."
        return 1
    fi

    echo "Installing an Ubuntu GPU driver because ALLOW_HOST_NVIDIA_DRIVER_INSTALL=1."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get install -y ubuntu-drivers-common "${kernel_headers}" || return 1
    ubuntu-drivers install --gpgpu || return 1

    driver_package="$(ubuntu-drivers list --gpgpu | awk '/^nvidia-driver-[0-9]+-server/{print $1; exit}')"
    driver_package="${driver_package%,}"
    [[ -n "${driver_package}" ]] || return 1
    driver_suffix="${driver_package#nvidia-driver-}"
    utils_package="nvidia-utils-${driver_suffix%-open}"
    kernel_module="linux-modules-nvidia-${driver_suffix}-$(uname -r)"
    apt-get install -y "${utils_package}" "${kernel_module}" || return 1
    modprobe nvidia || return 1
}

install_nvidia_container_toolkit() {
    local keyring="/etc/apt/keyrings/nvidia-container-toolkit.gpg"
    local source_list="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

    if command -v nvidia-ctk >/dev/null 2>&1 && command -v nvidia-container-runtime >/dev/null 2>&1; then
        echo "NVIDIA Container Toolkit is already installed."
        return 0
    fi

    echo "Installing NVIDIA Container Toolkit."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get install -y ca-certificates curl gnupg || return 1

    install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o "${keyring}" || return 1
    chmod a+r "${keyring}" || return 1
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=${keyring}] https://#" \
        > "${source_list}" || return 1

    apt-get update || return 1
    apt-get install -y nvidia-container-toolkit || return 1
}

configure_nvidia_docker() {
    local daemon_config="/etc/docker/daemon.json"
    local backup
    local before
    local after

    backup="$(mktemp)"
    cp "${daemon_config}" "${backup}" || {
        rm -f "${backup}"
        return 1
    }
    before="$(sha256sum "${daemon_config}")"

    if ! nvidia-ctk runtime configure --runtime=docker; then
        cp "${backup}" "${daemon_config}" || true
        rm -f "${backup}"
        return 1
    fi

    if ! python3 -m json.tool "${daemon_config}" >/dev/null; then
        echo "ERROR: NVIDIA Container Toolkit wrote invalid Docker configuration." >&2
        cp "${backup}" "${daemon_config}"
        rm -f "${backup}"
        return 1
    fi

    after="$(sha256sum "${daemon_config}")"
    rm -f "${backup}"
    if [[ "${before}" != "${after}" ]]; then
        echo "NVIDIA runtime configuration changed; restarting Docker."
        systemctl restart docker
    else
        echo "NVIDIA runtime is already configured in Docker."
    fi
}

docker_gpu_smoke_test() {
    echo "Validating Docker GPU access."
    docker run --rm --pull=missing --gpus all \
        nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi
}

setup_gpu_support() {
    if [[ "${GPU_MODE}" == "cpu" ]]; then
        echo "GPU_MODE=cpu; skipping NVIDIA setup."
        return 0
    fi

    if ! has_nvidia_hardware; then
        echo "No NVIDIA PCI device detected; using CPU mode."
        if [[ "${GPU_MODE}" == "gpu" ]]; then
            echo "ERROR: GPU_MODE=gpu was requested, but no NVIDIA GPU was detected." >&2
            return 1
        fi
        return 0
    fi

    echo "NVIDIA hardware detected."
    if ! has_nvidia_driver; then
        echo "NVIDIA driver is not ready."
        if ! install_nvidia_driver; then
            echo "Waiting for the host NVIDIA driver to become ready."
        fi
    fi

    if ! wait_for_nvidia_driver; then
        echo "WARNING: NVIDIA driver is unavailable; using CPU mode until the host driver is ready." >&2
        if [[ "${GPU_MODE}" == "gpu" ]]; then
            return 1
        fi
        return 0
    fi

    if ! install_nvidia_container_toolkit; then
        echo "WARNING: NVIDIA Container Toolkit installation failed; using CPU mode." >&2
        if [[ "${GPU_MODE}" == "gpu" ]]; then
            return 1
        fi
        return 0
    fi

    if ! configure_nvidia_docker; then
        echo "WARNING: NVIDIA Docker runtime configuration failed; using CPU mode." >&2
        if [[ "${GPU_MODE}" == "gpu" ]]; then
            return 1
        fi
        return 0
    fi

    if ! docker_gpu_smoke_test; then
        echo "WARNING: Docker could not access the NVIDIA GPU; using CPU mode." >&2
        if [[ "${GPU_MODE}" == "gpu" ]]; then
            return 1
        fi
        return 0
    fi

    ACCELERATION_MODE="gpu"
    echo "NVIDIA GPU access is ready."
}

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
DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
temporary_daemon_config="${DOCKER_DAEMON_CONFIG}.tmp"
python3 - "${DOCKER_DAEMON_CONFIG}" "${temporary_daemon_config}" "${DOCKER_DATA_ROOT}" <<'PY'
import json
import os
import sys

source, destination, data_root = sys.argv[1:]
if os.path.exists(source) and os.path.getsize(source):
    try:
        with open(source, encoding="utf-8") as handle:
            config = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Invalid Docker daemon configuration: {exc}")
else:
    config = {}

if not isinstance(config, dict):
    raise SystemExit("Docker daemon configuration must be a JSON object")

existing_root = config.get("data-root")
if existing_root is not None and existing_root != data_root:
    raise SystemExit(
        f'Docker daemon data-root is {existing_root!r}, expected {data_root!r}'
    )

config["data-root"] = data_root
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
os.chmod(destination, 0o644)
PY
mv "${temporary_daemon_config}" "${DOCKER_DAEMON_CONFIG}"

systemctl enable docker
systemctl restart docker

setup_gpu_support

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
COMPOSE_FILES=(-f compose.yaml)
if [[ "${ACCELERATION_MODE}" == "gpu" ]]; then
    COMPOSE_FILES+=(-f compose.gpu.yaml)
fi

echo "Starting Compose in ${ACCELERATION_MODE^^} mode."
compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "${COMPOSE_FILES[@]}" "$@"
    else
        docker-compose "${COMPOSE_FILES[@]}" "$@"
    fi
}

compose config >/dev/null
compose up --build -d
compose exec -T jupyter \
    ssh -i /home/jovyan/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes \
    -o UpdateHostKeys=no \
    opencode@host.docker.internal "sudo -n true"

echo
echo "[$(date -Is)] Setup complete."
echo "Credentials are shown in the CloudLab Profile Instructions."
echo "Services:"
echo "  JupyterLab: http://$(hostname -f):8888/lab"
echo "  OpenCode:   http://$(hostname -f):4096"
echo "  Acceleration: ${ACCELERATION_MODE^^}"
compose ps
