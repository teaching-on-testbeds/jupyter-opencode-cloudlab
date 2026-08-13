"""Launch JupyterLab and OpenCode on a CloudLab node.

This repository is intended to be used as a repository-based CloudLab profile.
CloudLab automatically clones the repository to /local/repository on the
experiment node and runs the included startup script.

Instructions:
Wait for the experiment to become ready and for the startup service to finish.

## JupyterLab

URL: http://{host-node}:8888/lab?token={password-jupyterToken}

Token: `{password-jupyterToken}`

## OpenCode

URL: http://{host-node}:4096/L2hvbWUvam92eWFuL3dvcmsvcHJvamVjdA/session

Username: `opencode`

Password: `{password-opencodePassword}`

## SSH

The repository is available at `/local/repository`.

If the services are still starting, inspect:

    sudo tail -f /var/log/cloudlab-jupyter-opencode-setup.log

Direct HTTP access is not encrypted. For an encrypted connection, use SSH
port forwarding as described in README.md.
"""

import re

import geni.portal as portal
import geni.rspec.igext as ig
import geni.rspec.pg as rspec
import geni.rspec.emulab  # Loads CloudLab/Emulab RSpec extensions.


pc = portal.Context()

# Compute resource selection.
pc.defineParameter(
    "resourceType",
    "Resource Type",
    portal.ParameterType.STRING,
    "raw",
    legalValues=[
        ("raw", "Physical node"),
        ("xenvm", "Xen VM"),
    ],
    longDescription=(
        "Use a dedicated physical CloudLab node or a Xen virtual machine. "
        "Xen VMs request a routable control IP so the web interfaces can be "
        "reached directly."
    ),
)

pc.defineParameter(
    "nodeType",
    "Node Type",
    portal.ParameterType.NODETYPE,
    "",
    longDescription=(
        "Optional physical node type. Leave blank to let CloudLab choose. "
        "For a Xen VM, this constrains the physical host on which the VM runs. "
        "The supplied container image requires an x86-64 node type."
    ),
)

# Xen VM sizing. These are advanced because most users only need to choose
# physical vs. Xen and can keep these defaults.
pc.defineParameter(
    "xenCores",
    "Xen VM CPU Cores",
    portal.ParameterType.INTEGER,
    4,
    advanced=True,
    longDescription="Number of virtual CPU cores when Resource Type is Xen VM.",
)

pc.defineParameter(
    "xenRam",
    "Xen VM RAM (MB)",
    portal.ParameterType.INTEGER,
    8192,
    advanced=True,
    longDescription="RAM in MB when Resource Type is Xen VM.",
)

# Match the familiar CloudLab temporary-filesystem controls.
pc.defineParameter(
    "tempFileSystemSize",
    "Temporary Filesystem Size",
    portal.ParameterType.INTEGER,
    0,
    advanced=True,
    longDescription=(
        "Size in GB of an ephemeral local filesystem. Set to zero to disable "
        "unless Temp Filesystem Max Space is selected. The filesystem is lost "
        "when the experiment terminates."
    ),
)

pc.defineParameter(
    "tempFileSystemMax",
    "Temp Filesystem Max Space",
    portal.ParameterType.BOOLEAN,
    False,
    advanced=True,
    longDescription=(
        "Use all available local space for the temporary filesystem. "
        "Leave Temporary Filesystem Size at zero when selecting this option."
    ),
)

pc.defineParameter(
    "tempFileSystemMount",
    "Temporary Filesystem Mount Point",
    portal.ParameterType.STRING,
    "/mydata",
    advanced=True,
    longDescription="Mount point for the ephemeral temporary filesystem.",
)

params = pc.bindParameters()

# Validate parameters before constructing resources.
if params.xenCores < 1:
    pc.reportError(
        portal.ParameterError(
            "Xen VM CPU cores must be at least 1.",
            ["xenCores"],
        )
    )

if params.xenRam < 1024:
    pc.reportError(
        portal.ParameterError(
            "Xen VM RAM must be at least 1024 MB.",
            ["xenRam"],
        )
    )

if params.tempFileSystemSize < 0:
    pc.reportError(
        portal.ParameterError(
            "Temporary filesystem size cannot be negative.",
            ["tempFileSystemSize"],
        )
    )

if params.tempFileSystemMax and params.tempFileSystemSize != 0:
    pc.reportError(
        portal.ParameterError(
            "Set Temporary Filesystem Size to zero when requesting max space.",
            ["tempFileSystemSize", "tempFileSystemMax"],
        )
    )

if not re.match(r"^/[A-Za-z0-9._/-]+$", params.tempFileSystemMount):
    pc.reportError(
        portal.ParameterError(
            "Temporary filesystem mount point must be an absolute path.",
            ["tempFileSystemMount"],
        )
    )

if params.tempFileSystemMount in ("/", "/usr", "/usr/local", "/local/repository"):
    pc.reportError(
        portal.ParameterError(
            "Choose a dedicated mount point such as /mydata; do not cover a system directory.",
            ["tempFileSystemMount"],
        )
    )

pc.verifyParameters()

request = pc.makeRequestRSpec()

# CloudLab generates these once per experiment and exposes them in the
# rendered Profile Instructions. The startup service reads the same encrypted
# values from the experiment manifest.
jupyter_token = ig.Password("jupyterToken")
opencode_password = ig.Password("opencodePassword")
request.addResource(jupyter_token)
request.addResource(opencode_password)

if params.resourceType == "xenvm":
    node = request.XenVM("node")
    node.cores = params.xenCores
    node.ram = params.xenRam
    node.routable_control_ip = True
    if params.nodeType:
        node.xen_ptype = params.nodeType
else:
    node = request.RawPC("node")
    if params.nodeType:
        node.hardware_type = params.nodeType

# Use a current CloudLab-provided x86-64 Ubuntu image. The Jupyter/OpenCode
# environment itself is containerized, so the host image stays minimal.
node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

use_temp_fs = params.tempFileSystemMax or params.tempFileSystemSize > 0
if use_temp_fs:
    blockstore = node.Blockstore("scratch", params.tempFileSystemMount)
    if params.tempFileSystemMax:
        # CloudLab convention: 0GB means use the maximum available space.
        blockstore.size = "0GB"
    else:
        blockstore.size = str(params.tempFileSystemSize) + "GB"
    blockstore.placement = "any"
    data_root = params.tempFileSystemMount
else:
    data_root = "/local"

# Repository-based profiles are cloned automatically to /local/repository.
# Execute services run after the repository is available and on node boots.
node.addService(
    rspec.Execute(
        shell="bash",
        command=(
            "/local/repository/cloudlab-startup.sh "
            + data_root
        ),
    )
)

pc.printRequestRSpec(request)
