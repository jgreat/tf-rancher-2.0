variable "vnet" {}
variable "subnet" {}
variable "region" {}
variable "vnet_rg" {}
variable "rg" {}

variable "vm_size" {
  default = "Standard_D2s_v3"
}

variable "vm_count" {
  default = 3
}
