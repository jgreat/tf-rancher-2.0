provider "aws" {
  profile = "${var.aws_profile}"
  region  = "${var.aws_region}"
}

######################
### Data Sources
######################
data "null_data_source" "ssh" {
  inputs {
    public_key_file = "${var.ssh_private_key_file}.pub"
  }
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "${var.server_name}-rke"
  public_key = "${file(data.null_data_source.ssh.outputs["public_key_file"])}"
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

data "aws_route53_zone" "dns_zone" {
  name = "${var.domain_name}"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "available" {
  vpc_id = "${data.aws_vpc.default.id}"
}

resource "random_string" "password" {
  length  = 20
  special = true
}

data "null_data_source" "reg_pass" {
  inputs {
    random = "${bcrypt(random_string.password.result, 10)}"
  }
}

#######################
### Security Groups
#######################
resource "aws_security_group" "rancher_elb" {
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
    cidr_blocks = ["${var.my_ip_cidr}"]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "TCP"
    security_groups = ["${aws_security_group.rancher_elb.id}"]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "TCP"
    security_groups = ["${aws_security_group.rancher_elb.id}"]
  }

  # K8s kube-api for kubectl
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["${var.my_ip_cidr}"]
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
    cidr_blocks = ["${var.my_ip_cidr}"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = ["${aws_security_group.rancher_registry.id}"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = ["${aws_security_group.rancher_elb.id}"]
  }
}

resource "aws_security_group" "rancher_registry" {
  name   = "${var.server_name}-rancher-registry"
  vpc_id = "${data.aws_vpc.default.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["${var.my_ip_cidr}"]
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

#############################
### Instances
#############################
data "template_file" "cloud_config_server" {
  template = "${file("${path.module}/cloud-config-server.yaml")}"
}

resource "aws_instance" "rancher" {
  count         = "${var.node_count}"
  ami           = "${data.aws_ami.rancheros.image_id}"
  instance_type = "${var.instance_type}"
  key_name      = "${aws_key_pair.ssh_key.id}"
  user_data     = "${data.template_file.cloud_config_server.rendered}"

  vpc_security_group_ids      = ["${aws_security_group.rancher.id}"]
  subnet_id                   = "${data.aws_subnet_ids.available.ids[0]}"
  associate_public_ip_address = true

  root_block_device = {
    volume_type = "gp2"
    volume_size = "50"
  }

  tags = {
    "Name" = "${var.server_name}-${count.index}"
  }
}

data "template_file" "cloud_config_registry" {
  template = "${file("${path.module}/cloud-config-registry.yaml")}"

  vars {
    reg_user    = "${var.reg_user}"
    reg_pass    = "${data.null_data_source.reg_pass.outputs["random"]}"
    https_fqdn  = "${var.server_name}-registry.${var.domain_name}"
    https_email = "${var.email}"
  }
}

resource "aws_instance" "rancher_registry" {
  ami           = "${data.aws_ami.rancheros.image_id}"
  instance_type = "${var.instance_type}"
  key_name      = "${aws_key_pair.ssh_key.id}"
  user_data     = "${data.template_file.cloud_config_registry.rendered}"

  vpc_security_group_ids      = ["${aws_security_group.rancher_registry.id}"]
  subnet_id                   = "${data.aws_subnet_ids.available.ids[0]}"
  associate_public_ip_address = true

  root_block_device = {
    volume_type = "gp2"
    volume_size = "100"
  }

  tags = {
    "Name" = "${var.server_name}-registry-${count.index}"
  }
}

#########################
### ELB
#########################
resource "aws_elb" "rancher" {
  name            = "${var.server_name}"
  subnets         = ["${data.aws_subnet_ids.available.ids[0]}"]
  security_groups = ["${aws_security_group.rancher_elb.id}"]

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

#########################
### DNS
#########################
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

resource "aws_route53_record" "rancher_registry" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${var.server_name}-registry.${var.domain_name}"
  type    = "CNAME"
  ttl     = "5"
  records = ["${aws_instance.rancher_registry.public_dns}"]
}

################################
### Create RKE node definitions
################################
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
    public_ip            = "${element(aws_instance.rancher.*.public_ip, count.index)}"
    private_ip           = "${element(aws_instance.rancher.*.private_ip, count.index)}"
    ssh_private_key_file = "${var.ssh_private_key_file}"
  }
}

###########################
### Create RKE config
###########################
data "template_file" "rke" {
  template = <<EOF
nodes: 
$${nodes}

private_registries:
- url: $${url}
  user: $${user}
  password: "$${password}"
  is_default: true
EOF

  vars {
    nodes    = "${join("\n", data.template_file.rke_node.*.rendered)}"
    url      = "${var.server_name}-registry.${var.domain_name}"
    user     = "${var.reg_user}"
    password = "${random_string.password.result}"
  }
}

##########################################################
# Render cluster.yml file. Clean cluster files on destroy
##########################################################
resource "local_file" "rke" {
  content  = "${data.template_file.rke.rendered}"
  filename = "${path.module}/cluster.yml"

  provisioner "local-exec" {
    when    = "destroy"
    command = "rm -f ${path.module}/kube_config_cluster.yml"
  }
}

###########################
### Outputs
###########################
output "rancher_internal_address" {
  value = "${aws_instance.rancher.*.private_ip}"
}

output "rancher_address" {
  value = "${aws_instance.rancher.*.public_ip}"
}

output "rancher_registry_internal_address" {
  value = "${aws_instance.rancher_registry.private_ip}"
}

output "rancher_registry_address" {
  value = "${aws_instance.rancher_registry.public_ip}"
}

output "registry_user" {
  value = "${var.reg_user}"
}

output "registry_password" {
  value = "${random_string.password.result}"
}

output "registry_url" {
  value = "${var.server_name}-registry.${var.domain_name}"
}

output "rancher_url" {
  value = "https://${var.server_name}.${var.domain_name}"
}
