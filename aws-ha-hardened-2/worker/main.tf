terraform {
  backend "s3" {
    bucket         = "tf-states"
    key            = "aws-ha-hardened-2/worker-aws-rke.tfstate"
    region         = "us-west-2"
    dynamodb_table = "tf-state-lock"
  }
}

locals {
  name               = "aws-rke"
  instance_type      = "t3.large"
  worker_count       = 2
  controlplane_count = 3
}

provider "aws" {
  region  = "us-east-2"
  profile = "rancher-eng"
}

provider "rancher2" {
  api_url   = "${data.terraform_remote_state.rancher.rancher_url}"
  token_key = "${data.terraform_remote_state.rancher.rancher_token}"
}

# create cluster
resource "rancher2_cluster" "custom" {
  name = "${local.name}"
  rke_config {
    services {
      kubelet = {
        extra_args = {
          "streaming-connection-idle-timeout" = "1800s"
          "protect-kernel-defaults"           = "true"
          "make-iptables-util-chains"         = "true"
          "event-qps"                         = "0"
        }
      }
      kube_api = {
        pod_security_policy = true
        extra_args = {
          "anonymous-auth"                = "false"
          "profiling"                     = "false"
          "repair-malformed-updates"      = "false"
          "service-account-lookup"        = "true"
          "enable-admission-plugins"      = "ServiceAccount,NamespaceLifecycle,LimitRanger,PersistentVolumeLabel,DefaultStorageClass,ResourceQuota,DefaultTolerationSeconds,AlwaysPullImages,DenyEscalatingExec,NodeRestriction,EventRateLimit,PodSecurityPolicy"
          "encryption-provider-config"    = "/opt/kubernetes/encryption.yaml"
          "admission-control-config-file" = "/opt/kubernetes/admission.yaml"
          "audit-log-path"                = "/var/log/kube-audit/audit-log.json"
          "audit-log-maxage"              = "5"
          "audit-log-maxbackup"           = "5"
          "audit-log-maxsize"             = "100"
          "audit-log-format"              = "json"
          "audit-policy-file"             = "/opt/kubernetes/audit.yaml"
        }
        extra_binds = [
          "/var/log/kube-audit:/var/log/kube-audit",
          "/opt/kubernetes:/opt/kubernetes"
        ]
      }
      kube_controller = {
        extra_args = {
          "profiling"                   = "false"
          "address"                     = "127.0.0.1"
          "terminated-pod-gc-threshold" = "1000"
        }
      }
      # scheduler = {
      #   extra_args = {
      #     "profiling" = "false"
      #     "address"   = "127.0.0.1"
      #   }
      # }
    }
    # addons = "${file("${path.module}/addons.yaml")}"
  }
  enable_network_policy                   = true
  default_pod_security_policy_template_id = "restricted"
}

resource "aws_security_group" "rancher_worker" {
  name   = "${local.name}-rancher-worker-worker"
  vpc_id = "${data.aws_vpc.default.id}"

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

  # Open intra-worker
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

resource "aws_security_group_rule" "worker_kubelet" {
  security_group_id        = "${aws_security_group.rancher_worker.id}"
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "TCP"
  source_security_group_id = "${aws_security_group.rancher_controlplane.id}"
}

resource "aws_security_group_rule" "worker_overlay" {
  security_group_id        = "${aws_security_group.rancher_worker.id}"
  type                     = "ingress"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "UDP"
  source_security_group_id = "${aws_security_group.rancher_controlplane.id}"
}

resource "aws_security_group" "rancher_controlplane" {
  name   = "${local.name}-rancher-worker-controlplan"
  vpc_id = "${data.aws_vpc.default.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Open intra-controlplane
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

resource "aws_security_group_rule" "controlplane_kubeapi" {
  security_group_id        = "${aws_security_group.rancher_controlplane.id}"
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "TCP"
  source_security_group_id = "${aws_security_group.rancher_worker.id}"
}

resource "aws_security_group_rule" "controlplane_overlay" {
  security_group_id        = "${aws_security_group.rancher_controlplane.id}"
  type                     = "ingress"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "UDP"
  source_security_group_id = "${aws_security_group.rancher_worker.id}"
}

#############################
### Create Nodes
#############################
data "template_file" "cloud_config_controlplane" {
  template = "${file("${path.module}/cloud-config-controlplane.yaml")}"

  vars = {
    agent_cmd = "${lookup(rancher2_cluster.custom.cluster_registration_token[0], "node_command")}"
  }
}
data "template_file" "cloud_config_worker" {
  template = "${file("${path.module}/cloud-config-worker.yaml")}"

  vars = {
    agent_cmd = "${lookup(rancher2_cluster.custom.cluster_registration_token[0], "node_command")}"
  }
}

resource "aws_instance" "rancher_controlplane" {
  count         = "${local.controlplane_count}"
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "${local.instance_type}"
  key_name      = "${aws_key_pair.ssh.id}"
  user_data     = "${data.template_file.cloud_config_controlplane.rendered}"

  vpc_security_group_ids      = ["${aws_security_group.rancher_controlplane.id}"]
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

resource "aws_instance" "rancher_worker" {
  count         = "${local.worker_count}"
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "${local.instance_type}"
  key_name      = "${aws_key_pair.ssh.id}"
  user_data     = "${data.template_file.cloud_config_worker.rendered}"

  vpc_security_group_ids      = ["${aws_security_group.rancher_worker.id}"]
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
