"""Launch JupyterLab and OpenCode on a CloudLab node.

This profile sets up a CloudLab node with JupyterLab, VSCode, and OpenCode.

With this profile:

- you can work with your code in JupyterLab or VSCode,
- and you can also interact with your code, the coding environment, and the CloudLab host itself by giving natural language commands to OpenCode, an LLM coding assistant.

OpenCode comes pre-configured with access to two free and anonymous LLM inference providers.

After you instantiate this profile, the "Profile Instructions" will show links and credentials for JupyterLab, VSCode, and OpenCode.

Instructions:
Wait for the experiment to become ready and for the startup service to finish. Then, you can open these services in a web browser:

## JupyterLab

URL: http://{host-node}:8888/lab?token={password-jupyterToken}

Token: `{password-jupyterToken}`

## VS Code

URL: http://{host-node}:8888/vscode/?token={password-jupyterToken}&folder=/home/jovyan/work/project

## OpenCode

URL: http://{host-node}:4096/L2hvbWUvam92eWFuL3dvcmsvcHJvamVjdA==/session

Username: `opencode`

Password: `{password-opencodePassword}`

"""

import re

import geni.portal as portal
import geni.rspec.igext as ig
import geni.rspec.pg as rspec
import geni.rspec.emulab  # Loads CloudLab/Emulab RSpec extensions.


def shell_quote(value):
    """Quote a value for the shell available on the CloudLab node."""
    return "'" + value.replace("'", "'\"'\"'") + "'"


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

pc.defineParameterGroup("xen", "Xen VM Settings")

pc.defineParameter(
    "xenCores",
    "Xen VM CPU Cores",
    portal.ParameterType.INTEGER,
    4,
    groupId="xen",
    longDescription="Number of virtual CPU cores when Resource Type is Xen VM.",
)

pc.defineParameter(
    "xenRam",
    "Xen VM RAM (MB)",
    portal.ParameterType.INTEGER,
    8192,
    groupId="xen",
    longDescription="RAM in MB when Resource Type is Xen VM.",
)

pc.defineParameter(
    "xenDisk",
    "Xen VM Disk Size (GB)",
    portal.ParameterType.INTEGER,
    80,
    groupId="xen",
    longDescription="Disk size in GB when Resource Type is Xen VM.",
)

pc.defineParameter(
    "xenExclusive",
    "Exclusive Xen VM Host",
    portal.ParameterType.BOOLEAN,
    True,
    groupId="xen",
    longDescription=(
        "Reserve the Xen VM's physical host exclusively for this experiment. "
        "Disable this to allow the host to be shared with other experiments."
    ),
)

pc.defineParameter(
    "diskImage",
    "Disk Image",
    portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD",
    longDescription=(
        "CloudLab image URN to install on the node. The default is the "
        "standard Ubuntu 24 image; replace it with another image URN when "
        "needed."
    ),
)

pc.defineParameter(
    "publicGitUrl",
    "Public Git Repository URL (optional)",
    portal.ParameterType.STRING,
    "",
    longDescription=(
        "Leave blank to start with an empty Git repository. If supplied, use "
        "an HTTPS URL for a public Git repository; it is cloned into "
        "/home/jovyan/work/project on first startup."
    ),
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

if params.xenDisk < 1:
    pc.reportError(
        portal.ParameterError(
            "Xen VM disk size must be at least 1 GB.",
            ["xenDisk"],
        )
    )

if not params.diskImage.startswith("urn:"):
    pc.reportError(
        portal.ParameterError(
            "Disk Image must be a CloudLab image URN.",
            ["diskImage"],
        )
    )

if params.publicGitUrl:
    if not re.match(r"^https://[^/\s]+(?:/[^\r\n]*)?$", params.publicGitUrl):
        pc.reportError(
            portal.ParameterError(
                "Public Git Repository URL must be an HTTPS URL.",
                ["publicGitUrl"],
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
    node = request.XenVM("node", exclusive=params.xenExclusive)
    node.cores = params.xenCores
    node.ram = params.xenRam
    node.disk = params.xenDisk
    node.routable_control_ip = True
    if params.nodeType:
        node.xen_ptype = params.nodeType
else:
    node = request.RawPC("node")
    if params.nodeType:
        node.hardware_type = params.nodeType

node.disk_image = params.diskImage

blockstore = node.Blockstore("scratch", "/mydata")
if params.resourceType == "xenvm":
    # Xen topology validation requires an explicit positive blockstore size.
    blockstore.size = "{}GB".format(params.xenDisk)
else:
    # A 0GB local blockstore uses all available space on physical nodes.
    blockstore.size = "0GB"
blockstore.placement = "any"
data_root = "/mydata"

# Repository-based profiles are cloned automatically to /local/repository.
# Execute services run after the repository is available and on node boots.
node.addService(
    rspec.Execute(
        shell="bash",
        command=(
            "/local/repository/cloudlab-startup.sh "
            + shell_quote(data_root)
            + " "
            + shell_quote(params.publicGitUrl)
        ),
    )
)

pc.printRequestRSpec(request)
