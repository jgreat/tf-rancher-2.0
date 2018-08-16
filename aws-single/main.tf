provider "aws" {
  profile = "${var.aws_profile}"
  region  = "${var.aws_region}"
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "${var.server_name}"
  public_key = "${file(var.ssh_public_key_file)}"
}

data "aws_route53_zone" "public" {
  name = "${var.domain}"
}

data "aws_ami" "rancheros" {
  most_recent = true
  owners      = ["605812595337"]

  filter {
    name   = "name"
    values = ["rancheros-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "nodes" {
  name = "${var.server_name}-cluster"

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

  # K8s kube-api
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K8s NodePort
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Open intra-cluster
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rancher_server" {
  name        = "${var.server_name}-server"
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

data "template_file" "rancher_server_user_data" {
  template = "${file("${path.module}/cloud-config.yml")}"

  vars = {
    # rancher_version = "${var.rancher_version}"  # # Domain to register with LetsEncrypt  # extra_commands = "command: --acme-domain ${var.server_name}.${var.domain}"
  }
}

resource "aws_instance" "node" {
  ami                         = "${data.aws_ami.rancheros.image_id}"
  instance_type               = "m5.large"
  associate_public_ip_address = true
  user_data                   = "${data.template_file.rancher_server_user_data.rendered}"
  key_name                    = "${aws_key_pair.ssh_key.key_name}"

  security_groups = [
    "${aws_security_group.rancher_server.name}",
    "${aws_security_group.nodes.name}",
  ]

  root_block_device = {
    volume_type = "gp2"
    volume_size = "40"
  }

  tags {
    Name = "${var.server_name}"
  }

  provisioner "remote-exec" {
    inline = [
      "docker run -d --name rancher-server -v /var/lib/rancher:/var/lib/rancher -p 80:80 -p 443:443 ${var.rancher_version} --acme-domain ${var.server_name}.${var.domain}",
    ]

    connection {
      type        = "ssh"
      user        = "rancher"
      private_key = "${file(var.ssh_private_key_file)}"
    }
  }
}

resource "aws_route53_record" "public" {
  zone_id = "${data.aws_route53_zone.public.zone_id}"
  name    = "${var.server_name}.${var.domain}."
  type    = "A"
  ttl     = "300"
  records = ["${aws_instance.node.public_ip}"]
}

resource "aws_route53_record" "private" {
  zone_id = "${data.aws_route53_zone.public.zone_id}"
  name    = "private-${var.server_name}.${var.domain}."
  type    = "A"
  ttl     = "300"
  records = ["${aws_instance.node.private_ip}"]
}
