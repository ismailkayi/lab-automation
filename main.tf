# ==============================================================================
# CANONICAL LAB INFRASTRUCTURE AS CODE
# Provider: LXD
# Orchestration: Terraform + Ansible
# ==============================================================================

terraform {
  required_providers {
    lxd = {
      source  = "terraform-lxd/lxd"
      version = "~> 2.3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
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

resource "lxd_profile" "lab_base" {
  name = "${var.user_prefix}-iac-base"

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

resource "lxd_instance" "microcloud_nodes" {
  count    = var.scenario == "microcloud" ? 3 : 0
  name     = "${var.user_prefix}-microcloud-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]

  limits = {
    cpu    = "2"
    memory = "4GiB"
  }

  config = {
    "user.user-data" = "#cloud-config\n"
  }
}

resource "lxd_volume" "microcloud_ceph_disks" {
  count = var.scenario == "microcloud" ? 3 : 0
  name  = "${var.user_prefix}-microcloud-ceph-${count.index + 1}"
  pool  = "default"
  type  = "block"
  config = { size = "50GiB" }
}

resource "lxd_instance" "k8s_nodes" {
  count    = var.scenario == "k8s-snap" ? 3 : 0
  name     = "${var.user_prefix}-k8s-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]

  limits = {
    cpu    = "2"
    memory = "4GiB"
  }

  config = {
    "user.user-data" = "#cloud-config\n"
  }
}

resource "lxd_instance" "juju_controller" {
  count    = contains(["juju-k8s", "juju-ceph"], var.scenario) ? 1 : 0
  name     = "${var.user_prefix}-juju-controller"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]
  
  limits = {
    cpu    = "4"
    memory = "8GiB"
  }

  config = {
    "user.user-data" = "#cloud-config\n"
  }
}

resource "lxd_instance" "juju_workers" {
  count    = contains(["juju-k8s", "juju-ceph"], var.scenario) ? 3 : 0
  name     = "${var.user_prefix}-juju-worker-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]
  
  limits = {
    cpu    = "2"
    memory = "4GiB"
  }

  config = {
    "user.user-data" = "#cloud-config\n"
  }
}

resource "lxd_volume" "juju_ceph_disks" {
  count = var.scenario == "juju-ceph" ? 3 : 0
  name  = "${var.user_prefix}-juju-ceph-${count.index + 1}"
  pool  = "default"
  type  = "block"
  config = { size = "50GiB" }
}

# --- ANSIBLE INVENTORY GENERATION ---
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
        juju_controller = {
          hosts = { for name in lxd_instance.juju_controller[*].name : name => { ansible_connection = "lxd" } }
        }
        juju_workers = {
          hosts = { for name in lxd_instance.juju_workers[*].name : name => { ansible_connection = "lxd" } }
        }
      }
    }
  })
  filename        = "${path.module}/inventory.yaml"
  file_permission = "0644"
}