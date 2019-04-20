# Azure

## Requirements

* Azure DNS Zone
* Vnet
* Subnet

Make sure your vnet/subnet are in the same region that you are trying to create the resources in.

## Resources

This will create 3 nodes in an availability set with a public facing load-balancer in front.

DNS will be created pointed at the LB: `${var.rg}.${var.domain}`

## Usage

Create a terraform.tfvars file

```plain
region = "West US"

# existing vnet in this region
vnet = "my-vnet"

# resource group for vnet
vnet_rg = "my-network"

# subnet in vnet
subnet = "subnet-1"

# Resource group to create (also rancher dns name)
rg = "rancher"

# Domain - Azure DNS Zone
domain = "my.domain.com"

# Resource Group for Azure DNS Zone
dns_zone_rg = "my-domain-com"
```

```plain
terraform init
terraform apply
```

## Outputs

A ready to run RKE cluster.yml file will be in ./outputs

```plain
rke up --config ./outputs/cluster.yml
```
