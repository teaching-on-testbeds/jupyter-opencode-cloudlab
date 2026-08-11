#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="/local/repository"
DATA_ROOT="${1:-/local}"
ENV_FILE="${REPO_DIR}/.env"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

MANIFEST_FILE="${TMP_DIR}/manifest.xml"
KEY_FILE="${TMP_DIR}/geni.key"

echo "[$(date -Is)] Starting CloudLab Jupyter/OpenCode startup"

/usr/local/etc/emulab/tmcc.bin geni_manifest > "${MANIFEST_FILE}"
/usr/local/etc/emulab/tmcc.bin geni_key > "${KEY_FILE}"

python3 - "${MANIFEST_FILE}" "${KEY_FILE}" "${ENV_FILE}" "${DATA_ROOT}" <<'PY'
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

manifest_path, key_path, env_path, data_root = map(Path, sys.argv[1:])
manifest = manifest_path.read_bytes()
manifest = manifest[manifest.find(b"<") :]
root = ET.fromstring(manifest)
password_names = {"jupyterToken", "opencodePassword"}
passwords = {}

with tempfile.TemporaryDirectory() as work_dir:
    decrypt_key = Path(work_dir) / "geni.key"
    decrypt_key.write_bytes(key_path.read_bytes().lstrip(b"\0"))
    for element in root:
        if element.tag.rsplit("}", 1)[-1] != "password":
            continue
        name = element.get("name")
        if name not in password_names:
            continue
        result = subprocess.run(
            [
                "openssl",
                "smime",
                "-decrypt",
                "-inform",
                "PEM",
                "-inkey",
                str(decrypt_key),
                "-in",
                "-",
            ],
            input=(element.text or "").encode(),
            stdout=subprocess.PIPE,
            check=True,
        )
        value = result.stdout.decode().strip()
        if not value or "\n" in value or "\r" in value:
            raise RuntimeError("CloudLab returned an invalid password")
        passwords[name] = value

missing = password_names - passwords.keys()
if missing:
    raise RuntimeError("Missing CloudLab password resources: " + ", ".join(sorted(missing)))

content = "\n".join(
    [
        "JUPYTER_PORT=8888",
        "OPENCODE_PORT=4096",
        "BIND_ADDRESS=0.0.0.0",
        f"JUPYTER_DATA_DIR={data_root}/jupyter-data",
        "OPENCODE_PROJECT_DIR=project",
        f"JUPYTER_TOKEN={passwords['jupyterToken']}",
        "OPENCODE_SERVER_USERNAME=opencode",
        f"OPENCODE_SERVER_PASSWORD={passwords['opencodePassword']}",
        "",
    ]
)

temporary_env = env_path.with_name(env_path.name + ".tmp")
temporary_env.write_text(content)
os.chmod(temporary_env, 0o600)
os.replace(temporary_env, env_path)
PY

exec "${REPO_DIR}/setup.sh" "${DATA_ROOT}"
