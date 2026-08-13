# CloudLab Jupyter + OpenCode

Launch a JupyterLab + OpenCode environment as a repository-based CloudLab profile.

### Parameters

- **Resource Type**: physical node or Xen VM.
- **Node Type**: optional CloudLab physical node type. For Xen VMs this constrains the VM host.
- **Xen VM Settings**: collapsed settings for the 80 GB default disk, CPU cores, RAM, and exclusive-host allocation. Xen VMs use an exclusive physical host by default.
- **Disk Image**: CloudLab image URN, defaulting to the standard Ubuntu 24 image.
- **Public Git Repository URL (optional)**: blank starts an empty project; an HTTPS URL clones a public repository into the project directory.

The supplied Jupyter/PyTorch CUDA container is x86-64; select an x86-64 CloudLab
node type. ARM node types are not supported by this image.

On physical nodes, the profile requests the maximum available temporary local
filesystem at `/mydata` (`0GB` blockstore convention). Both the Jupyter
workspace and Docker's image/layer storage are placed under it. Xen VMs use
their VM disk under `/local` instead, because a separate local blockstore is
not supported consistently for shared Xen allocations. These paths survive a
node reboot but are ephemeral and disappear when the CloudLab experiment
terminates.

## Access the services

When the experiment is ready, CloudLab substitutes the node FQDN into the
profile Instructions via `{host-node}`.

The generated Jupyter token and OpenCode password are displayed directly in
the CloudLab experiment's Profile Instructions. They are generated once per
experiment and reused by the running services.

Then open:

```text
http://<node-fqdn>:8888/lab/?token=<jupyter-token>
http://<node-fqdn>:8888/vscode/?token=<jupyter-token>&folder=/home/jovyan/work/project
http://<node-fqdn>:4096
```

JupyterLab and VS Code use `JUPYTER_TOKEN`. OpenCode uses
`OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD`.


## Host access from OpenCode

CloudLab startup creates an `opencode` user on the host and gives it
passwordless sudo access. It also generates a dedicated SSH key, mounts the
private key read-only in the container, and pins the host's SSH keys. The
container remains unprivileged.

Each project contains `HOST.md` with the command OpenCode can use to run
commands on the host:

```bash
ssh -i /home/jovyan/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes -o UpdateHostKeys=no opencode@host.docker.internal '<command>'
```

Prefix the remote command with `sudo` when root access is required. Anyone who
can execute commands in the container can use this key for root-equivalent
access to the experiment host.
