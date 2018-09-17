provider "aws" {
  profile = "${var.aws_profile}"
  region  = "${var.aws_region}"
}

data "null_data_source" "ssh" {
  inputs {
    public_key_file = "${var.ssh_private_key_file}.pub"
  }
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "${var.server_name}-rke"
  public_key = "${file(data.null_data_source.ssh.outputs["public_key_file"])}"
}

data "aws_ami" "ami" {
  most_recent = true
  owners      = ["${lookup(var.ami, "${var.os}.owner")}"]

  filter {
    name   = "name"
    values = ["${lookup(var.ami, "${var.os}.name")}"]
  }

  filter {
    name   = "virtualization-type"
    values = ["${lookup(var.ami, "${var.os}.virtualization_type")}"]
  }
  filter {
    name = "root-device-type"
    values = ["${lookup(var.ami, "${var.os}.root_device_type")}"]
  }
}

data "aws_route53_zone" "dns_zone" {
  name = "${var.domain_name}"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "available" {
  vpc_id = "${data.aws_vpc.default.id}"
}

resource "aws_security_group" "rancher-elb" {
  name   = "${var.server_name}-rancher-elb"
  vpc_id = "${data.aws_vpc.default.id}"

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

  ingress {
    from_port   = 6443
    to_port     = 6443
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

resource "aws_security_group" "rancher" {
  name   = "${var.server_name}-rancher-server"
  vpc_id = "${data.aws_vpc.default.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "TCP"
    security_groups = ["${aws_security_group.rancher-elb.id}"]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "TCP"
    security_groups = ["${aws_security_group.rancher-elb.id}"]
  }

  # K8s kube-api for kubectl
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K8s NodePorts
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

data "template_file" "cloud_config" {
  template = "${file("${path.module}/${var.os}-cloud-config.yaml")}"
}

resource "aws_instance" "rancher" {
  count         = "${var.node_count}"
  ami           = "${data.aws_ami.ami.image_id}"
  instance_type = "${var.instance_type}"
  key_name      = "${aws_key_pair.ssh_key.id}"
  user_data     = "${data.template_file.cloud_config.rendered}"

  vpc_security_group_ids      = ["${aws_security_group.rancher.id}"]
  subnet_id                   = "${data.aws_subnet_ids.available.ids[0]}"
  associate_public_ip_address = true

  #  iam_instance_profile = "k8s-ec2-route53"

  root_block_device = {
    volume_type = "gp2"
    volume_size = "50"
  }
  tags = {
    "Name" = "${var.server_name}-${count.index}"
  }
}

resource "aws_elb" "rancher" {
  name            = "${var.server_name}"
  subnets         = ["${data.aws_subnet_ids.available.ids[0]}"]
  security_groups = ["${aws_security_group.rancher-elb.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "tcp"
    lb_port           = 80
    lb_protocol       = "tcp"
  }

  listener {
    instance_port     = 443
    instance_protocol = "tcp"
    lb_port           = 443
    lb_protocol       = "tcp"
  }

  listener {
    instance_port     = 6443
    instance_protocol = "tcp"
    lb_port           = 6443
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "tcp:80"
    interval            = 5
  }

  instances    = ["${aws_instance.rancher.*.id}"]
  idle_timeout = 1800

  tags {
    Name = "${var.server_name}"
  }
}

# DNS
resource "aws_route53_record" "rancher" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${var.server_name}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = "${aws_elb.rancher.dns_name}"
    zone_id                = "${aws_elb.rancher.zone_id}"
    evaluate_target_health = true
  }
}

# Create RKE node definitions
data "template_file" "rke_node" {
  count = "${var.node_count}"

  template = <<EON
- address: $${public_ip}
  internal_address: $${private_ip}
  user: rancher
  role: [ "controlplane", "etcd", "worker" ]
  ssh_key_file: $${ssh_private_key_file}
EON

  vars {
    public_ip           = "${element(aws_instance.rancher.*.public_ip, count.index)}"
    private_ip          = "${element(aws_instance.rancher.*.private_ip, count.index)}"
    ssh_private_key_file = "${var.ssh_private_key_file}"
  }
}

# #Create RKE config
data "template_file" "rke" {
  template = <<EOF
nodes: 
$${nodes}
EOF

  vars {
    nodes = "${join("\n", data.template_file.rke_node.*.rendered)}"
  }
}

# Render RKE config file.
resource "local_file" "rke" {
  content  = "${data.template_file.rke.rendered}"
  filename = "${path.module}/cluster.yml"

  # provisioner "local-exec" {
  #   command = "sleep 120"
  # }

  # provisioner "local-exec" {
  #   command = "rke up --config ${path.module}/cluster.yml 2>&1 | tee ${path.module}/rke_log.out"
  # }

  # provisioner "local-exec" {
  #   command = "KUBECONFIG=${path.module}/kube_config_cluster.yml kubectl -n kube-system create serviceaccount tiller"
  # }

  # provisioner "local-exec" {
  #   command = "KUBECONFIG=${path.module}/kube_config_cluster.yml kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller"
  # }

  # provisioner "local-exec" {
  #   command = "KUBECONFIG=${path.module}/kube_config_cluster.yml helm init --service-account tiller --wait"
  # }

  # provisioner "local-exec" {
  #   command = "KUBECONFIG=${path.module}/kube_config_cluster.yml helm repo add rancher-stable https://releases.rancher.com/server-charts/stable"
  # }

  # provisioner "local-exec" {
  #   command = "KUBECONFIG=${path.module}/kube_config_cluster.yml helm install stable/cert-manager --name cert-manager --namespace kube-system --wait"
  # }

  # provisioner "local-exec" {
  #   command = "KUBECONFIG=${path.module}/kube_config_cluster.yml helm install rancher-stable/rancher --name rancher --namespace cattle-system --set hostname=${var.server_name}.${var.domain_name} --wait"
  # }

  provisioner "local-exec" {
    when = "destroy"
    command = "rm -f ${path.module}/kube_config_cluster.yml ${path.module}/rke_log.out"
  }
}

output "internal_address" {
  value = "${aws_instance.rancher.*.private_ip}"
}

output "address" {
  value = "${aws_instance.rancher.*.public_ip}"
}

output "rancher_url" {
  value = "https://${var.server_name}.${var.domain_name}"
}
