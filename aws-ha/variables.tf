variable "aws_profile" {
  default = "default"
}

variable "aws_region" {}
variable "domain_name" {}

variable "instance_type" {
  default = "m5.xlarge"
}

variable "node_count" {
  default = 3
}

variable "os" {
  default = "rancheros"
}

variable "ami" {
  type = "map"

  default = {
    rancheros.owner               = "605812595337"
    rancheros.name                = "rancheros-*"
    rancheros.virtualization_type = "hvm"
    rancheros.root_device_type    = "ebs"
    rancheros.default_user        = "rancher"
    ubuntu.owner                  = "099720109477"
    ubuntu.name                   = "*ubuntu-xenial-16.04-*"
    ubuntu.virtualization_type    = "hvm"
    ubuntu.root_device_type       = "ebs"
    ubuntu.default_user           = "ubuntu"
  }
}

variable "server_name" {}
variable "ssh_private_key_file" {}
