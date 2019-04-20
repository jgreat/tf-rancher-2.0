# Azure

## Requirements

* Azure DNS Zone
* Vnet
* Subnet

Make sure your vnet/subnet are in the same region that you are trying to create the resources in.

## Resources

This will create 3 nodes in an availability set with a public facing load-balancer in front.

DNS will be created pointed at the LB: `${var.rg}.${var.domain}`

## Outputs

A ready to run RKE cluster.yml file will be in ./outputs

```plain
rke up --config ./outputs/cluster.yml
```
