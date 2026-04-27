# ==============================================================================
# CANONICAL LAB INFRASTRUCTURE AS CODE
# Provider: LXD
# Orchestration: OpenTofu + Ansible
# ==============================================================================

terraform {
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

variable "k8s_control_plane_count" {
  description = "Number of Canonical Kubernetes control-plane nodes"
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.k8s_control_plane_count)
    error_message = "k8s_control_plane_count must be either 1 or 3."
  }
}

variable "k8s_worker_count" {
  description = "Number of worker-only Canonical Kubernetes nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.k8s_worker_count >= 0
    error_message = "k8s_worker_count must be 0 or greater."
  }
}

variable "lxd_network_name" {
  description = "Primary LXD bridge network name used for VM eth0"
  type        = string
}

variable "lxd_storage_pool" {
  description = "LXD storage pool name used for VM root disks and MicroCloud Ceph disks"
  type        = string
}

variable "microcloud_node_cpu" {
  description = "vCPU count per MicroCloud node"
  type        = number
  default     = 2

  validation {
    condition     = var.microcloud_node_cpu >= 1
    error_message = "microcloud_node_cpu must be 1 or greater."
  }
}

variable "microcloud_node_memory_mb" {
  description = "Memory in MiB per MicroCloud node"
  type        = number
  default     = 4096

  validation {
    condition     = var.microcloud_node_memory_mb >= 1024
    error_message = "microcloud_node_memory_mb must be at least 1024 MiB."
  }
}

variable "microcloud_root_disk_size_gib" {
  description = "Root disk size in GiB per MicroCloud node"
  type        = number
  default     = 40

  validation {
    condition     = var.microcloud_root_disk_size_gib >= 20
    error_message = "microcloud_root_disk_size_gib must be at least 20 GiB."
  }
}

variable "microcloud_ceph_disk_size_gib" {
  description = "Ceph data disk size in GiB per MicroCloud node"
  type        = number
  default     = 50

  validation {
    condition     = var.microcloud_ceph_disk_size_gib >= 10
    error_message = "microcloud_ceph_disk_size_gib must be at least 10 GiB."
  }
}

locals {
  # Original environment ID for local files (e.g., ismail_microcloud)
  env_id = terraform.workspace == "default" ? var.user_prefix : terraform.workspace
  
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
      network = var.lxd_network_name
    }
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      pool = var.lxd_storage_pool
      path = "/"
      size = "${var.microcloud_root_disk_size_gib}GiB"
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
  pool         = var.lxd_storage_pool
  content_type = "block"
  config       = { size = "${var.microcloud_ceph_disk_size_gib}GiB" }
}

resource "lxd_instance" "microcloud_nodes" {
  count    = var.scenario == "microcloud" ? 3 : 0
  name     = "${local.lxd_prefix}-node-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]

  limits = {
    cpu    = tostring(var.microcloud_node_cpu)
    memory = "${var.microcloud_node_memory_mb}MiB"
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
      pool   = var.lxd_storage_pool
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
resource "lxd_instance" "k8s_control_plane_nodes" {
  count    = var.scenario == "k8s-snap" ? var.k8s_control_plane_count : 0
  name     = "${local.lxd_prefix}-k8s-cp-${count.index + 1}"
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

resource "lxd_instance" "k8s_worker_nodes" {
  count    = var.scenario == "k8s-snap" ? var.k8s_worker_count : 0
  name     = "${local.lxd_prefix}-k8s-worker-${count.index + 1}"
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
          hosts = merge(
            { for name in lxd_instance.k8s_control_plane_nodes[*].name : name => { ansible_connection = "lxd", k8s_role = "control-plane" } },
            { for name in lxd_instance.k8s_worker_nodes[*].name : name => { ansible_connection = "lxd", k8s_role = "worker" } }
          )
        }
        k8s_control_plane = {
          hosts = { for name in lxd_instance.k8s_control_plane_nodes[*].name : name => { ansible_connection = "lxd" } }
        }
        k8s_workers = {
          hosts = { for name in lxd_instance.k8s_worker_nodes[*].name : name => { ansible_connection = "lxd" } }
        }
      }
    }
  })
  # We keep the filename aligned with the workspace name (env_id) so orchestrate.sh can find it
  filename        = "${path.module}/inventory_${local.env_id}.yaml"
  file_permission = "0644"
}