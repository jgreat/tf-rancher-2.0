provider "azurestack" { }

resource "azurestack_resource_group" "network" {
  name     = "k8s-"
  location = "West US"
}

# Create a virtual network within the resource group
resource "azurestack_virtual_network" "network" {
  name                = "production-network"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurestack_resource_group.network.location}"
  resource_group_name = "${azurestack_resource_group.network.name}"

  subnet {
    name           = "subnet1"
    address_prefix = "10.0.1.0/24"
  }

  subnet {
    name           = "subnet2"
    address_prefix = "10.0.2.0/24"
  }

  subnet {
    name           = "subnet3"
    address_prefix = "10.0.3.0/24"
  }
}