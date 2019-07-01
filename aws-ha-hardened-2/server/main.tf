terraform {
  backend "s3" {
    bucket         = "tf-states"
    key            = "aws-ha-hardened-2/rancher_server.tfstate"
    region         = "us-west-2"
    dynamodb_table = "tf-state-lock"
  }
}

locals {
  name             = "rancher-hardened"
  domain           = "jgreat.me"
  rancher_password = "changemetosomethinggood"
  instance_type    = "t3.large"
  node_count       = 3
}

provider "aws" {
  region  = "us-east-2"
  profile = "rancher-eng"
}

provider "rke" {}

provider "helm" {
  install_tiller  = true
  namespace       = "kube-system"
  service_account = "tiller"

  kubernetes {
    host                   = "${rke_cluster.rancher_server.api_server_url}"
    username               = "${rke_cluster.rancher_server.kube_admin_user}"
    client_certificate     = "${rke_cluster.rancher_server.client_cert}"
    client_key             = "${rke_cluster.rancher_server.client_key}"
    cluster_ca_certificate = "${rke_cluster.rancher_server.ca_crt}"
  }
}

provider "rancher2" {
  alias     = "bootstrap"
  api_url   = "https://${local.name}.${local.domain}"
  bootstrap = true
}

# need elb
resource "aws_security_group" "rancher_elb" {
  name   = "${local.name}-rancher-elb"
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
  name   = "${local.name}-rancher-server"
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
    security_groups = ["${aws_security_group.rancher_elb.id}"]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "TCP"
    security_groups = ["${aws_security_group.rancher_elb.id}"]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

#############################
### Create Nodes
#############################
data "template_file" "cloud_config" {
  template = "${file("${path.module}/cloud-config.yaml")}"
}

resource "aws_instance" "rancher" {
  count         = "${local.node_count}"
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "${local.instance_type}"
  key_name      = "${aws_key_pair.ssh.id}"
  user_data     = "${data.template_file.cloud_config.rendered}"

  vpc_security_group_ids      = ["${aws_security_group.rancher.id}"]
  subnet_id                   = "${data.aws_subnet_ids.available.ids[0]}"
  associate_public_ip_address = true

  # iam_instance_profile = "${var.aws_iam_profile}"

  root_block_device = {
    volume_type = "gp2"
    volume_size = "50"
  }
  tags = {
    Name = "${local.name}"
  }
}

resource "aws_elb" "rancher" {
  name            = "${local.name}"
  subnets         = ["${data.aws_subnet_ids.available.ids}"]
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

  tags = {
    Name = "${local.name}"
  }
}

resource "aws_route53_record" "rancher" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${local.name}.${local.domain}"
  type    = "A"

  alias {
    name                   = "${aws_elb.rancher.dns_name}"
    zone_id                = "${aws_elb.rancher.zone_id}"
    evaluate_target_health = true
  }
}

########################################
### Wait for docker install on nodes
########################################
resource "null_resource" "wait_for_docker" {
  count = "${local.node_count}"

  triggers = {
    instance_ids = "${join(",", aws_instance.rancher.*.id)}"
  }

  provisioner "local-exec" {
    command = <<EOF
while [ "$${RET}" -gt 0 ]; do
    ssh -q -o StrictHostKeyChecking=no -i $${KEY} $${USER}@$${IP} 'docker ps 2>&1 >/dev/null'
    RET=$$?
    if [ "$${RET}" -gt 0 ]; then
        sleep 10
    fi
done
EOF
    environment {
      RET = "1"
      USER = "ubuntu"
      IP = "${element(aws_instance.rancher.*.public_ip, count.index)}"
      KEY = "${path.root}/outputs/id_rsa"
    }
  }
}

###########################
### RKE Nodes
###########################
data "rke_node_parameter" "rancher_server" {
  depends_on = [
    "null_resource.wait_for_docker"
  ]
  count = "${local.node_count}"

  address = "${element(aws_instance.rancher.*.public_ip, count.index)}"
  internal_address = "${element(aws_instance.rancher.*.private_ip, count.index)}"
  user = "ubuntu"
  role = ["controlplane", "worker", "etcd"]
  ssh_key = "${tls_private_key.ssh.private_key_pem}"
}

############################
### RKE Cluster
###########################
resource "rke_cluster" "rancher_server" {
  nodes_conf = ["${data.rke_node_parameter.rancher_server.*.json}"]
  cluster_name = "rancher-management"
  services_kubelet = {
    extra_args = {
      "streaming-connection-idle-timeout" = "1800s"
      "protect-kernel-defaults" = "true"
      "make-iptables-util-chains" = "true"
      "event-qps" = "0"
    }
  }
  services_kube_api = {
    pod_security_policy = true
    extra_args = {
      "anonymous-auth" = "false"
      "profiling" = "false"
      "repair-malformed-updates" = "false"
      "service-account-lookup" = "true"
      "enable-admission-plugins" = "ServiceAccount,NamespaceLifecycle,LimitRanger,PersistentVolumeLabel,DefaultStorageClass,ResourceQuota,DefaultTolerationSeconds,AlwaysPullImages,DenyEscalatingExec,NodeRestriction,EventRateLimit,PodSecurityPolicy"
      "encryption-provider-config" = "/opt/kubernetes/encryption.yaml"
      "admission-control-config-file" = "/opt/kubernetes/admission.yaml"
      "audit-log-path" = "/var/log/kube-audit/audit-log.json"
      "audit-log-maxage" = "5"
      "audit-log-maxbackup" = "5"
      "audit-log-maxsize" = "100"
      "audit-log-format" = "json"
      "audit-policy-file" = "/opt/kubernetes/audit.yaml"
    }
    extra_binds = [
      "/var/log/kube-audit:/var/log/kube-audit",
      "/opt/kubernetes:/opt/kubernetes"
    ]
  }
  services_kube_controller = {
    extra_args = {
      "profiling" = "false"
      "address" = "127.0.0.1"
      "terminated-pod-gc-threshold" = "1000"
    }
  }
  services_scheduler = {
    extra_args = {
      "profiling" = "false"
      "address" = "127.0.0.1"
    }
  }
  addons = "${file("${path.module}/addons.yaml")}"
}

resource "local_file" "kube_cluster_yaml" {
  filename = "${path.root}/outputs/kube_config_cluster.yml"
  content = "${rke_cluster.rancher_server.kube_config_yaml}"
}

# install rancher
resource "helm_release" "cert_manager" {
  version = "v0.5.2"
  name = "cert-manager"
  chart = "stable/cert-manager"
  namespace = "kube-system"

  # Bogus set to link togeather resources for proper tear down
  set {
    name = "tf_link"
    value = "${rke_cluster.rancher_server.api_server_url}"
  }
}

resource "helm_release" "rancher" {

  name = "rancher"
  chart = "${lookup(data.helm_repository.rancher_stable.metadata[0], "name")}/rancher"
  namespace = "cattle-system"

  set {
    name = "hostname"
    value = "${local.name}.${local.domain}"
  }
  set {
    name = "ingress.tls.source"
    value = "letsEncrypt"
  }
  set {
    name = "letsEncrypt.email"
    value = "none@none.com"
  }
  set {
    name = "addLocal"
    value = "false"
  }
  # Bogus set to link togeather resources for proper tear down
  set = {
    name = "tf_link"
    value = "${helm_release.cert_manager.name}"
  }
}

resource "null_resource" "wait_for_rancher" {

  provisioner "local-exec" {
    command = <<EOF
while [ "$${subject}" != "*  subject: CN=$${RANCHER_HOSTNAME}" ]; do
    subject=$$(curl -vk -m 2 "https://$${RANCHER_HOSTNAME}/ping" 2>&1 | grep "subject:")
    echo "Cert Subject Response: $${subject}"
    if [ "$${subject}" != "*  subject: CN=$${RANCHER_HOSTNAME}" ]; then
      sleep 10
    fi
done
while [ "$${resp}" != "pong" ]; do
    resp=$$(curl -sSk -m 2 "https://$${RANCHER_HOSTNAME}/ping")
    echo "Rancher Response: $${resp}"
    if [ "$${resp}" != "pong" ]; then
      sleep 10
    fi
done
EOF
    environment {
      RANCHER_HOSTNAME = "${local.name}.${local.domain}"
      TF_LINK          = "${lookup(helm_release.rancher.metadata[0], "name")}"
    }
  }
}

resource "rancher2_bootstrap" "admin" {
  provider = "rancher2.bootstrap"
  depends_on = [
    "null_resource.wait_for_rancher"
  ]
  password = "${local.rancher_password}"
}
