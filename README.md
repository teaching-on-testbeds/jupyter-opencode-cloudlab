# CloudLab Jupyter + OpenCode

Launch a JupyterLab + OpenCode environment as a repository-based CloudLab profile.
Both web applications use the same workspace.

This is the CloudLab counterpart of `teaching-on-testbeds/chi-jupyter-opencode`.
The Chameleon launch/cleanup notebooks and object-storage integration are intentionally omitted.

## CloudLab profile

CloudLab repository-based profiles automatically clone this repository to:

```text
/local/repository
```

The top-level `profile.py` requests one physical node or Xen VM and registers
`/local/repository/setup.sh` as an Execute service. The startup script installs
Docker, creates per-experiment credentials, and starts JupyterLab and OpenCode.
It is idempotent because CloudLab Execute services run again after a node reboot.

### Parameters

- **Resource Type**: physical node or Xen VM.
- **Node Type**: optional CloudLab physical node type. For Xen VMs this constrains the VM host.
- **Xen VM CPU Cores / RAM**: advanced Xen sizing controls.
- **Temporary Filesystem Size**: requested ephemeral local storage in GB.
- **Temp Filesystem Max Space**: use all available local storage (`0GB` blockstore convention).
- **Temporary Filesystem Mount Point**: defaults to `/mydata`.

The supplied Jupyter/PyTorch CUDA container is x86-64; select an x86-64 CloudLab
node type. ARM node types are not supported by this image.

If a temporary filesystem is enabled, both the Jupyter workspace and Docker's
image/layer storage are placed under that filesystem. Otherwise they use `/local`.
All of this data is ephemeral and disappears when the CloudLab experiment terminates.

## Create the CloudLab profile

1. Push this directory to a public Git repository.
2. In CloudLab, create a new profile from a Git repository URL.
3. CloudLab will detect the top-level `profile.py`.
4. Instantiate the profile and choose the resource/storage parameters.

CloudLab documentation:

- Repository-based profiles: https://docs.cloudlab.us/creating-profiles.html
- geni-lib profiles: https://docs.cloudlab.us/geni-lib.html
- Storage: https://docs.cloudlab.us/advanced-storage.html

## Access the services

When the experiment is ready, CloudLab substitutes the node FQDN into the
profile Instructions via `{host-node}`.

The generated Jupyter token and OpenCode password are displayed directly in
the CloudLab experiment's Profile Instructions. They are generated once per
experiment and reused by the running services.

Then open:

```text
http://<node-fqdn>:8888/lab
http://<node-fqdn>:4096
```

Jupyter uses `JUPYTER_TOKEN`. OpenCode uses `OPENCODE_SERVER_USERNAME` and
`OPENCODE_SERVER_PASSWORD`.

### SSH forwarding (recommended for encrypted transport)

Direct access to ports 8888 and 4096 is HTTP, so credentials and traffic are
not encrypted. You can instead bind the services to loopback by changing
`BIND_ADDRESS=127.0.0.1` in `/local/repository/.env`, restarting Compose, and
forwarding the ports over SSH:

```bash
ssh -L 8888:127.0.0.1:8888 -L 4096:127.0.0.1:4096 <cloudlab-user>@<node-fqdn>
```

Then use `http://127.0.0.1:8888/lab` and `http://127.0.0.1:4096` locally.

## Service management

```bash
cd /local/repository
sudo docker compose ps
sudo docker compose logs -f jupyter
sudo docker compose restart
```

Startup-script output is written to:

```text
/var/log/cloudlab-jupyter-opencode-setup.log
```

## GPU nodes

The repository retains the optional GPU Compose overlay from the Chameleon
version. If the selected physical CloudLab node has a working NVIDIA driver and
NVIDIA Container Toolkit, restart with:

```bash
cd /local/repository
sudo docker compose -f compose.yaml -f compose.gpu.yaml up --build -d
```

Check access with:

```bash
sudo docker compose exec jupyter nvidia-smi
sudo docker compose exec jupyter python -c 'import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))'
```

## Local/manual startup

Outside CloudLab, copy `.env.example` to `.env`, replace the two credential
placeholders, and run:

```bash
docker compose up --build -d
```

On first startup, the container creates
`/home/jovyan/work/<OPENCODE_PROJECT_DIR>` as a Git repository and opens it as
OpenCode's default project. JupyterLab uses `/home/jovyan/work` as its root.
