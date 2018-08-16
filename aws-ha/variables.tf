variable "aws_profile" {
  default = "default"
}

variable "aws_region" {}
variable "domain_name" {}

variable "instance_type" {
  default = "m5.large"
}

variable "node_count" {
  default = 3
}

variable "server_name" {}
variable "ssh_private_key_file" {}
