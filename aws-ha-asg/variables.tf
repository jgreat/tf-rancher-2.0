variable "aws_profile" {
  default = "default"
}

variable "aws_region" {
  default = "us-east-2"
}

variable "domain" {}

variable "instance_type" {
  default = "m5.xlarge"
}

variable "name" {}

variable "rancher_version" {
  default = "latest"
}

variable "rke_version" {
  default = "v0.2.1"
}

variable "ros_version" {
  default = "v1.5.1-hvm-1"
}
