data "aws_ami" "rancheros" {
  most_recent = true
  owners      = ["605812595337"]

  filter {
    name   = "name"
    values = ["rancheros-${var.ros_version}"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

data "aws_route53_zone" "dns_zone" {
  name = "${var.domain}"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "available" {
  vpc_id = "${data.aws_vpc.default.id}"
}
