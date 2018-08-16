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

data "template_file" "rancher_server_user_data" {
  template = "${file("${path.module}/cloud-config.yml")}"

  vars = {
    rancher_version = "${var.rancher_version}"
    server_name     = "${var.server_name}"
  }
}

# TODO: aws IAM profile

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

resource "aws_instance" "nodes" {
  count                       = "${var.node_count}"
  ami                         = "${data.aws_ami.rancheros.image_id}"
  instance_type               = "m5.large"
  associate_public_ip_address = true
  user_data                   = "${data.template_file.rancher_server_user_data.rendered}"
  key_name                    = "${aws_key_pair.ssh_key.key_name}"
  iam_instance_profile        = "k8s-ec2-route53"

  security_groups = [
    "${aws_security_group.rancher_server.name}",
    "${aws_security_group.nodes.name}",
  ]

  root_block_device = {
    volume_type = "gp2"
    volume_size = "40"
  }

  tags {
    Name      = "${var.server_name}-${count.index}"
    CreatedBy = "${var.me}"
  }
}

resource "aws_route53_record" "public_node" {
  count   = "${var.node_count}"
  zone_id = "${data.aws_route53_zone.public.zone_id}"
  name    = "${var.server_name}-${count.index}.${var.domain}."
  type    = "CNAME"
  ttl     = "300"
  records = ["${element(aws_instance.nodes.*.public_dns, count.index)}"]
}

resource "aws_route53_record" "private_node" {
  count   = "${var.node_count}"
  zone_id = "${data.aws_route53_zone.public.zone_id}"
  name    = "private-${var.server_name}-${count.index}.${var.domain}."
  type    = "CNAME"
  ttl     = "300"
  records = ["${element(aws_instance.nodes.*.private_dns, count.index)}"]
}

resource "aws_route53_record" "public" {
  zone_id = "${data.aws_route53_zone.public.zone_id}"
  name    = "${var.server_name}.${var.domain}."
  type    = "A"
  ttl     = "300"
  records = ["${aws_instance.nodes.*.public_ip}"]
}

resource "aws_route53_record" "private" {
  zone_id = "${data.aws_route53_zone.public.zone_id}"
  name    = "private-${var.server_name}.${var.domain}."
  type    = "A"
  ttl     = "300"
  records = ["${aws_instance.nodes.*.private_ip}"]
}

# template file rancher-ssl-passthrough.yml
data "template_file" "rancher-ssl-passthrough" {
  template = "${file("${path.module}/k8s/rancher-ssl-passthrough-template.yml")}"

  vars {
    fqdn = "${var.server_name}.${var.domain}"
    rancher_image = "rancher/server:${var.rancher_version}"
  }
}

resource "local_file" "rancher-ssl-passthrough" {
  content  = "${data.template_file.rancher-ssl-passthrough.rendered}"
  filename = "${path.module}/k8s/rancher-ssl-passthrough.yml"
}

resource "rke_cluster" "rancher" {
  cluster_name = "rancher"
  cloud_provider = {
    name = "aws"
  }
  ingress = {
    provider = "nginx"
    options = {
      enable-ssl-passthrough = "true"
    }
  }
  nodes = [
    {
      address           = "${element(aws_instance.nodes.*.public_dns, 0)}"
      internal_address  = "${element(aws_instance.nodes.*.private_dns, 0)}"
      hostname_override = "${var.server_name}-0.${var.domain}"
      user              = "rancher"
      role              = ["controlplane", "etcd", "worker"]
    },
    {
      address           = "${element(aws_instance.nodes.*.public_dns, 1)}"
      internal_address  = "${element(aws_instance.nodes.*.private_dns, 1)}"
      hostname_override = "${var.server_name}-1.${var.domain}"
      user              = "rancher"
      role              = ["controlplane", "etcd", "worker"]
    },
    {
      address           = "${element(aws_instance.nodes.*.public_dns, 2)}"
      internal_address  = "${element(aws_instance.nodes.*.private_dns, 2)}"
      hostname_override = "${var.server_name}-2.${var.domain}"
      user              = "rancher"
      role              = ["controlplane", "etcd", "worker"]
    }
  ]
  addons_include = [
    # "${path.module}/k8s/external-dns.yml",
    "${path.module}/k8s/rancher-ssl-passthrough.yml"
  ]

  depends_on = [
    "aws_route53_record.public",
    "local_file.rancher-ssl-passthrough"
  ]
}

resource "local_file" "kube_cluster_yaml" {
  filename = "${path.module}/kube_config_cluster.yml"
  content = "${rke_cluster.rancher.kube_config_yaml}"
}