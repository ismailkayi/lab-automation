# ==============================================================================
# CANONICAL LAB INFRASTRUCTURE AS CODE
# Provider: LXD
# Orchestration: Terraform + Cloud-init
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
    "security.nesting"    = "true"
    "security.secureboot" = "false"
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

  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "4GiB"
    "user.user-data" = <<-EOT
      #cloud-config
      package_update: true
      snap:
        commands:
          - snap install lxd microcloud microceph microovn
    EOT
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

  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "4GiB"
    "user.user-data" = <<-EOT
      #cloud-config
      package_update: true
      snap:
        commands:
          - snap install k8s --channel=latest/stable --classic
    EOT
  }
}

resource "lxd_instance" "juju_controller" {
  count    = contains(["juju-k8s", "juju-ceph"], var.scenario) ? 1 : 0
  name     = "${var.user_prefix}-juju-controller"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]
  config = {
    "limits.cpu"    = "4"
    "limits.memory" = "8GiB"
    "user.user-data" = "#cloud-config\nsnap:\n  commands:\n    - snap install juju --classic"
  }
}

resource "lxd_instance" "juju_workers" {
  count    = contains(["juju-k8s", "juju-ceph"], var.scenario) ? 3 : 0
  name     = "${var.user_prefix}-juju-worker-${count.index + 1}"
  image    = var.ubuntu_image
  type     = "virtual-machine"
  profiles = [lxd_profile.lab_base.name]
  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "4GiB"
    "user.user-data" = var.scenario == "juju-ceph" ? "#cloud-config\nsnap:\n  commands:\n    - snap install microceph" : "#cloud-config\n"
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
# This block automatically writes the instance names into an Ansible inventory file.
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tmpl", {
    microcloud_nodes = lxd_instance.microcloud_nodes[*].name
    k8s_nodes        = lxd_instance.k8s_nodes[*].name
    juju_controller  = lxd_instance.juju_controller[*].name
    juju_workers     = lxd_instance.juju_workers[*].name
  })
  filename = "${path.module}/inventory.ini"
}