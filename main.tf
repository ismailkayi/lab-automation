# ==============================================================================
# CANONICAL LAB INFRASTRUCTURE AS CODE
# Provider: LXD
# Orchestration: OpenTofu + Ansible
# ==============================================================================

tofu {
  required_providers {
    lxd = {
      source  = "terraform-lxd/lxd"
      version = "~> 2.4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5.0"
    }
  }
}

provider "lxd" {}

variable "user_prefix" {
  description = "User prefix for resource isolation"
  type        = string
  default     = "lab"
}

variable "scenario" {
  description = "Deployment scenario"
  type        = string
  default     = "microcloud"
}

variable "ubuntu_image" {
  description = "LXD image reference"
  type        = string
  default     = "ubuntu:24.04"
}

variable "ssh_public_key" {
  description = "Host SSH public key to inject into VMs for access"
  type        = string
}

locals {
  # Original environment ID for local files (e.g., ismail_microcloud)
  env_id = tofu.workspace == "default" ? var.user_prefix : tofu.workspace
  
  # LXD safe prefix: Replaces underscores with hyphens to strictly comply with LXD naming rules
  # (e.g., "ismail_microcloud" becomes "ismail-microcloud")
  lxd_prefix = replace(local.env_id, "_", "-")
}

resource "lxd_profile" "lab_base" {
  name = "${local.lxd_prefix}-iac-base"

  config = {
    "security.nesting" = "true"
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = "lxdbr0"
    }
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      pool = "default"
      path = "/"
      size = "40GiB"
    }
  }
}

# --- SCENARIOS ---

# Network without IP for MicroOVN (Uplink)
resource "lxd_network" "ovn_uplink" {
  count = var.scenario == "microcloud" ? 1 : 0
  # Limit network name to 15 characters to avoid LXD bridge name limits
  name  = "mc-${substr(local.lxd_prefix, 0, 8)}-up"
  type  = "bridge"
  config = {
    "ipv4.address" = "none"
    "ipv6.address" = "none"
  }
}

# Additional disks for MicroCeph
resource "lxd_volume" "microcloud_ceph_disks" {
  count        = var.scenario == "microcloud" ? 3 : 0
  name         = "${local.lxd_prefix}-ceph-${count.index + 1}"
  pool         = "default"
  content_type = "block"
  config       = { size = "50GiB" }
}

resource "lxd_instance" "microcloud_nodes" {
  count    = var.scenario == "microcloud" ? 3 : 0
  name     = "${local.lxd_prefix}-node-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]

  limits = {
    cpu    = "2"
    memory = "4GiB"
  }

  # Second Network Interface (MicroOVN)
  device {
    name = "eth1"
    type = "nic"
    properties = {
      network = lxd_network.ovn_uplink[0].name
    }
  }

  # Additional Disk Attachment (MicroCeph)
  device {
    name = "ceph-disk"
    type = "disk"
    properties = {
      source = lxd_volume.microcloud_ceph_disks[count.index].name
      pool   = "default"
    }
  }

  # SSH Key Injection
  config = {
    "user.user-data" = <<-EOT
      #cloud-config
      ssh_authorized_keys:
        - ${var.ssh_public_key}
    EOT
  }
}

# --- K8S SNAP NODES ---
resource "lxd_instance" "k8s_nodes" {
  count    = var.scenario == "k8s-snap" ? 3 : 0
  name     = "${local.lxd_prefix}-k8s-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]

  limits = {
    cpu    = "2"
    memory = "4GiB"
  }

  config = {
    "user.user-data" = <<-EOT
      #cloud-config
      ssh_authorized_keys:
        - ${var.ssh_public_key}
    EOT
  }
}

# --- ANSIBLE INVENTORY GENERATION ---
# Each environment creates its own inventory file to prevent conflicts
resource "local_file" "ansible_inventory" {
  content = yamlencode({
    all = {
      children = {
        microcloud = {
          hosts = { for name in lxd_instance.microcloud_nodes[*].name : name => { ansible_connection = "lxd" } }
        }
        k8s_snap = {
          hosts = { for name in lxd_instance.k8s_nodes[*].name : name => { ansible_connection = "lxd" } }
        }
      }
    }
  })
  # We keep the filename aligned with the workspace name (env_id) so orchestrate.sh can find it
  filename        = "${path.module}/inventory_${local.env_id}.yaml"
  file_permission = "0644"
}