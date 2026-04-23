# Canonical Lab Automation

Canonical Lab Automation creates local Canonical labs on top of LXD virtual machines.

Supported scenarios:

- Canonical Kubernetes (Snap)
- MicroCloud

Main entrypoint:

```bash
./orchestrate.sh
```

## Quick Start

From the repository root:

```bash
chmod +x orchestrate.sh
./orchestrate.sh
```

You will then choose one of these options:

```text
1) Deploy Canonical K8s (Snap)
2) Deploy MicroCloud (3 Node MicroCloud w/ Ceph & OVN)
3) Destroy Environments
```

## Requirements

Before you start, make sure:

- LXD is installed and working
- the LXD `default` storage pool exists
- you can run `lxc` commands on the host
- the host has internet access

The script can install missing tools automatically when needed:

- OpenTofu
- Ansible
- required Ansible collection(s)

It also creates an SSH key automatically if needed:

- `~/.ssh/id_rsa_lab`

## How Naming Works

You enter a simple lab prefix such as:

```text
ismail
```

The script converts it into a workspace name automatically:

- Kubernetes: `ismail_k8s-snap`
- MicroCloud: `ismail_microcloud`

If you enter the full workspace name by mistake, the script normalizes it automatically.

## Deploying Canonical Kubernetes

Kubernetes supports:

- `1` or `3` control-plane nodes
- `0` or more worker-only nodes

Default values:

- `3` control-plane nodes
- `1` worker-only node

Prompts:

```text
Number of control-plane nodes [default: 3, allowed: 1 or 3]:
Number of worker-only nodes [default: 1, enter 0 for none]:
```

At the end of a successful deployment, the script prints:

- cluster nodes
- Kubernetes API endpoint
- node status from `kubectl get nodes -o wide`

### Existing Kubernetes Lab

If the lab name already exists, the script shows the current topology and asks what to do:

- `add`: expand the cluster
- `rebuild`: destroy and recreate the cluster
- `cancel`: stop the operation

Important:

- growing is supported
- shrinking in place is not supported
- to reduce node count, use `rebuild`

## Deploying MicroCloud

MicroCloud currently uses a fixed topology:

- `3` nodes
- MicroCeph enabled
- MicroOVN enabled

At the end of a successful deployment, the script prints:

- cluster health
- cluster nodes
- UI access links on port `8443`

## Destroying an Environment

Choose:

```text
3) Destroy Environments
```

Then:

1. Select the environment from the list
2. Confirm by typing `yes`

## SSH Access

After deployment, connect with:

```bash
ssh -i ~/.ssh/id_rsa_lab ubuntu@<VM_IP>
```

## Typical Usage Examples

### New Kubernetes Lab

1. Run `./orchestrate.sh`
2. Choose `Deploy Canonical K8s (Snap)`
3. Enter a lab prefix such as `demo`
4. Accept defaults or choose your topology

### Expand an Existing Kubernetes Lab

1. Run `./orchestrate.sh`
2. Choose `Deploy Canonical K8s (Snap)`
3. Enter the same lab prefix as before
4. Choose `add`
5. Increase control-plane or worker-only count

### New MicroCloud Lab

1. Run `./orchestrate.sh`
2. Choose `Deploy MicroCloud (3 Node MicroCloud w/ Ceph & OVN)`
3. Enter a lab prefix

## Notes

- Kubernetes re-runs are designed to be safe and idempotent
- MicroCloud re-runs are intended for verification and reconciliation of a healthy cluster
- MicroCloud Terraform apply runs serially to reduce provider race issues during volume creation

## Troubleshooting

### The lab already exists

Use the same lab name again.

For Kubernetes, the script will guide you through `add`, `rebuild`, or `cancel`.

### I want fewer Kubernetes nodes than I have now

In-place shrink is intentionally blocked. Use `rebuild`.

### A MicroCloud deployment failed midway

Use the destroy workflow and deploy again.

## Summary

Run `./orchestrate.sh`, choose a scenario, enter a lab name, and let the script build or manage the environment for you.
