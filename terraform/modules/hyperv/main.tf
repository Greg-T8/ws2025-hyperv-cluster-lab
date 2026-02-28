# -------------------------------------------------------------------------
# Program: main.tf
# Description: Hyper-V VM and disk resources for cluster lab infrastructure
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Create one OS VHDX per cluster node.
resource "hyperv_vhd" "os_disk" {
  for_each = toset(local.vm_names)

  path     = "${var.vm_path}\\${each.value}\\Virtual Hard Disks\\${each.value}-OS.vhdx"
  size     = local.os_disk_size_bytes
  vhd_type = "Dynamic"
}

# Create the OS VHDX for the Active Directory domain controller VM.
resource "hyperv_vhd" "domain_controller_os_disk" {
  path     = "${var.vm_path}\\${local.domain_controller_name}\\Virtual Hard Disks\\${local.domain_controller_name}-OS.vhdx"
  size     = local.os_disk_size_bytes
  vhd_type = "Dynamic"
}

# Create shared CSV VHDX disks used by all cluster nodes.
resource "hyperv_vhd" "shared_csv" {
  for_each = local.csv_disk_map

  path     = "${local.shared_disk_folder}\\CSV-Disk-${each.key}.vhdx"
  size     = local.csv_disk_size_bytes
  vhd_type = "Fixed"
}

# Create a shared witness VHDX disk used for cluster quorum.
resource "hyperv_vhd" "shared_witness" {
  path     = "${local.shared_disk_folder}\\Witness-Disk.vhdx"
  size     = local.witness_disk_size_bytes
  vhd_type = "Fixed"
}

# Create and configure the Active Directory domain controller VM.
resource "hyperv_machine_instance" "domain_controller" {
  name                 = local.domain_controller_name
  generation           = var.vm_generation
  path                 = var.vm_path
  state                = "Running"
  checkpoint_type      = "Disabled"
  processor_count      = var.domain_controller_processor_count
  dynamic_memory       = true
  memory_startup_bytes = var.domain_controller_memory_startup_bytes
  memory_minimum_bytes = var.domain_controller_memory_minimum_bytes
  memory_maximum_bytes = var.domain_controller_memory_maximum_bytes

  # Attach one adapter to external Ethernet switch.
  network_adaptors {
    name        = "External"
    switch_name = var.management_switch_name
    wait_for_ips = false
  }

  # Attach one adapter to internal switch.
  network_adaptors {
    name        = "Internal"
    switch_name = var.internal_switch_name
    wait_for_ips = false
  }

  # Attach domain controller OS disk.
  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.domain_controller_os_disk.path
  }

  # Attach installation ISO to domain controller DVD drive.
  dvd_drives {
    controller_number   = 0
    controller_location = 1
    path                = var.iso_path
  }

  # Attach answer file ISO for unattended Windows Setup.
  dvd_drives {
    controller_number   = 0
    controller_location = 2
    path                = local.dc_answer_iso_path
  }

  # Set UEFI firmware with DVD-first boot order for OS installation.
  vm_firmware {
    enable_secure_boot    = "On"
    secure_boot_template  = "MicrosoftWindows"
    preferred_network_boot_protocol = "IPv4"
    pause_after_boot_failure        = "On"

    boot_order {
      boot_type           = "DvdDrive"
      controller_number   = 0
      controller_location = 1
    }

    boot_order {
      boot_type           = "HardDiskDrive"
      controller_number   = 0
      controller_location = 0
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "External"
      switch_name          = var.management_switch_name
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Internal"
      switch_name          = var.internal_switch_name
    }
  }

  # Enable standard integration services for guest operations.
  integration_services = {
    "Guest Service Interface" = true
    "Heartbeat"               = true
    "Key-Value Pair Exchange" = true
    "Shutdown"                = true
    "Time Synchronization"    = true
    "VSS"                     = true
  }

  # Preserve manual secure boot and DVD adjustments made in Hyper-V Manager.
  lifecycle {
    ignore_changes = [
      dvd_drives,
      vm_processor,
    ]
  }
}

# Create and configure cluster node virtual machines.
resource "hyperv_machine_instance" "cluster_node" {
  for_each = toset(local.vm_names)

  name                 = each.value
  generation           = var.vm_generation
  path                 = var.vm_path
  state                = "Off"
  checkpoint_type      = "Disabled"
  processor_count      = var.processor_count
  dynamic_memory       = true
  memory_startup_bytes = var.memory_startup_bytes
  memory_minimum_bytes = var.memory_minimum_bytes
  memory_maximum_bytes = var.memory_maximum_bytes

  # Enable nested virtualization on each cluster node VM.
  vm_processor {
    expose_virtualization_extensions = true
  }

  # Attach two adapters for management on internal switch.
  network_adaptors {
    name                 = "Mgmt-1"
    switch_name          = var.internal_switch_name
    allow_teaming        = "On"
    mac_address_spoofing = "On"
    wait_for_ips         = false
  }

  network_adaptors {
    name                 = "Mgmt-2"
    switch_name          = var.internal_switch_name
    allow_teaming        = "On"
    mac_address_spoofing = "On"
    wait_for_ips         = false
  }

  # Attach two adapters for cluster management and live migration.
  network_adaptors {
    name                 = "Cluster-1"
    switch_name          = var.cluster_switch_name
    allow_teaming        = "On"
    mac_address_spoofing = "On"
    wait_for_ips         = false
  }

  network_adaptors {
    name                 = "Cluster-2"
    switch_name          = var.cluster_switch_name
    allow_teaming        = "On"
    mac_address_spoofing = "On"
    wait_for_ips         = false
  }

  # Attach two adapters for VM compute traffic on external Ethernet switch.
  network_adaptors {
    name                 = "Compute-1"
    switch_name          = var.management_switch_name
    allow_teaming        = "On"
    mac_address_spoofing = "On"
    wait_for_ips         = false
  }

  network_adaptors {
    name                 = "Compute-2"
    switch_name          = var.management_switch_name
    allow_teaming        = "On"
    mac_address_spoofing = "On"
    wait_for_ips         = false
  }

  # Attach per-node OS disk.
  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.os_disk[each.value].path
  }

  # NOTE: Shared CSV and witness disks require VHD Set (.vhds) or ReFS for
  # persistent SCSI reservations on a standalone Hyper-V host. NTFS does not
  # support shared VHDX. Attach these disks during cluster setup instead.

  # Attach installation ISO to DVD drive.
  dvd_drives {
    controller_number   = 0
    controller_location = 1
    path                = var.iso_path
  }

  # Attach answer file ISO for unattended Windows Setup.
  dvd_drives {
    controller_number   = 0
    controller_location = 2
    path                = local.node_answer_iso_path
  }

  # Set UEFI firmware with DVD-first boot order for OS installation.
  vm_firmware {
    enable_secure_boot    = "On"
    secure_boot_template  = "MicrosoftWindows"
    preferred_network_boot_protocol = "IPv4"
    pause_after_boot_failure        = "On"

    boot_order {
      boot_type           = "DvdDrive"
      controller_number   = 0
      controller_location = 1
    }

    boot_order {
      boot_type           = "HardDiskDrive"
      controller_number   = 0
      controller_location = 0
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Mgmt-1"
      switch_name          = var.internal_switch_name
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Mgmt-2"
      switch_name          = var.internal_switch_name
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Cluster-1"
      switch_name          = var.cluster_switch_name
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Cluster-2"
      switch_name          = var.cluster_switch_name
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Compute-1"
      switch_name          = var.management_switch_name
    }

    boot_order {
      boot_type            = "NetworkAdapter"
      network_adapter_name = "Compute-2"
      switch_name          = var.management_switch_name
    }
  }

  # Enable standard integration services for guest operations.
  integration_services = {
    "Guest Service Interface" = true
    "Heartbeat"               = true
    "Key-Value Pair Exchange" = true
    "Shutdown"                = true
    "Time Synchronization"    = true
    "VSS"                     = true
  }

  # Preserve manual secure boot, DVD adjustments, and running state after AD-gated start.
  lifecycle {
    ignore_changes = [
      dvd_drives,
      state,
      vm_processor,
    ]
  }

  depends_on = [hyperv_machine_instance.domain_controller]
}
