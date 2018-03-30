provider "aws" {
  profile = "${var.aws_profile}"
  region  = "${var.aws_region}"
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "${var.me}_rancher2"
  public_key = "${file(var.ssh_public_key_file)}"
}

# My domain is in route53
data "aws_route53_zone" "dns_zone" {
  name = "${var.domain}"
}

data "template_file" "rancher_server_user_data" {
  template = "${file("${path.module}/cloud-config.yml")}"

  vars = {
    rancher_version = "${var.rancher_version}"
    server_name     = "${var.server_name}"
  }
}

resource "aws_security_group" "rancher_server" {
  name        = "rancher_2_server_1"
  description = "Allow 22, 80, 443"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "rancher_server" {
  ami                         = "ami-a383b6c6"
  instance_type               = "m5.large"
  associate_public_ip_address = true
  security_groups             = ["${aws_security_group.rancher_server.name}"]
  user_data                   = "${data.template_file.rancher_server_user_data.rendered}"
  key_name                    = "${aws_key_pair.ssh_key.key_name}"

  # spot_price = "0.02"

  root_block_device = {
    volume_type = "gp2"
    volume_size = "40"
  }
  tags {
    Name      = "rancher2-master"
    CreatedBy = "${var.me}"
  }
}

resource "aws_eip" "rancher_server" {
  instance = "${aws_instance.rancher_server.id}"
}

# resource "aws_eip_association" "proxy_eip" {
#   instance_id   = "${aws_instance.rancher_server.id}"
#   allocation_id = "${aws_eip.rancher_server.id}"
# }

resource "aws_route53_record" "rancher_server" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${var.server_name}."
  type    = "A"
  ttl     = "300"
  records = ["${aws_eip.rancher_server.public_ip}"]
}
