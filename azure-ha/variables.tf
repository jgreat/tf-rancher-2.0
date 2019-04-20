variable "vnet" {}
variable "subnet" {}
variable "region" {}
variable "vnet_rg" {}
variable "rg" {}

variable "domain" {}
variable "dns_zone_rg" {}

variable "vm_size" {
  default = "Standard_D4s_v3"
}

variable "vm_count" {
  default = 3
}
