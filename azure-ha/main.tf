provider "azurerm" {}

data "azurerm_subnet" "rancher" {
  name                 = "${var.subnet}"
  virtual_network_name = "${var.vnet}"
  resource_group_name  = "${var.vnet_rg}"
}

resource "azurerm_resource_group" "rancher" {
  name    = "${var.rg}"
  location = "${var.region}"
}

# storage account for bootdiag
resource "random_string" "sa_id" {
  length  = 4
  special = false
}

resource "azurerm_storage_account" "rancher" {
  name                     = "${var.rg}-sa-${random_string.sa_id.result}"
  location                 = "${azurerm_resource_group.rancher.location}"
  resource_group_name      = "${azurerm_resource_group.rancher.name}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_availability_set" "rancher" {
  name                = "${var.rg}-as"
  location            = "${azurerm_resource_group.rancher.location}"
  resource_group_name = "${azurerm_resource_group.rancher.name}"

  managed = true
}

resource "azurerm_public_ip" "rancher" {
  count                        = "${var.vm_count}"
  name                         = "${var.rg}-pip-${count.index}"
  location                     = "${azurerm_resource_group.rancher.location}"
  resource_group_name          = "${azurerm_resource_group.rancher.name}"
  public_ip_address_allocation = "static"
}

resource "azurerm_network_security_group" "rancher" {
  name                = "${var.rg}-nsg"
  location            = "${azurerm_resource_group.rancher.location}"
  resource_group_name = "${azurerm_resource_group.rancher.name}"

  security_rule {
    name                       = "allow_ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_port_range     = "22"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_ingress"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_port_ranges    = ["80", "443"]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_k8s_api"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_port_range     = "6443"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "rancher" {
  count               = "${var.vm_count}"
  name                = "${var.rg}-nic-${count.index}"
  location            = "${azurerm_resource_group.rancher.location}"
  resource_group_name = "${azurerm_resource_group.rancher.name}"

  network_security_group_id = "${azurerm_network_security_group.rancher.id}"

  ip_configuration {
    name                          = "ip-configuration-1"
    subnet_id                     = "${data.azurerm_subnet.rancher.id}"
    public_ip_address_id          = "${element(azurerm_public_ip.rancher.*.id, count.index)}"
    private_ip_address_allocation = "dynamic"
  }
}

resource "azurerm_virtual_machine" "rancher" {
  count               = "${var.vm_count}"
  name                = "${var.rg}-vm-${count.index}"
  location            = "${azurerm_resource_group.rancher.location}"
  resource_group_name = "${azurerm_resource_group.rancher.name}"

  vm_size                          = "${var.vm_size}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  availability_set_id = "${azurerm_availability_set.rancher.id}"

  network_interface_ids = ["${element(azurerm_network_interface.rancher.*.id, count.index)}"]

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name              = "${var.rg}-vm-${count.index}-osDisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
    disk_size_gb      = 128
  }

  os_profile {
    computer_name  = "${var.rg}-vm-${count.index}"
    admin_username = "rancher"
    user_data = "${file("ubuntu-cloud-config.yaml")}"
  }

  os_profile_linux_config {
    disable_password_authentication = true

    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}"
      path     = "/home/rancher/.ssh/authorized_keys"
    }
  }

  boot_diagnostics {
    enabled = true
    storage_uri = "${azurerm_storage_account.rancher.primary_blob_endpoint}"
  }
}

output "public_ips" {
  value = "${azurerm_public_ip.rancher.*.ip_address}"
}

output "private_ips" {
  value = "${azurerm_network_interface.rancher.*.private_ip_address}"
}