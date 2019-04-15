locals {
  tags = {
    Name                                = "${var.name}"
    "kubernetes.io/cluster/${var.name}" = "owned"
  }
}

resource "aws_security_group" "rke" {
  name   = "${var.name}"
  vpc_id = "${data.aws_vpc.default.id}"

  # ssh
  ingress = {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # kube-api
  ingress = {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Open intra-cluster
  ingress = {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress = {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle = {
    ignore_changes = [
      "ingress",
      "egress",
    ]
  }

  tags = "${local.tags}"
}

# base cluster.yml
# NOTE: Authenication block only works with new clusters.
#       Won't be able to update DNS name without rebuilding/rotating certs.
data "template_file" "base_cluster_yml" {
  template = <<EOF
authentication:
  strategy: x509
  sans:
  - $${fqdn}
cluster_name: $${name}
cloud_provider:
  name: aws
ingress:
  provider: none
addons: |-
  ---
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: tiller
    namespace: kube-system
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: tiller
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: cluster-admin
  subjects:
  - kind: ServiceAccount
    name: tiller
    namespace: kube-system
EOF

  vars = {
    name = "${var.name}"
    fqdn = "${aws_route53_record.kubeapi.fqdn}"
  }
}

resource "aws_s3_bucket_object" "base_cluster_yml" {
  bucket         = "${aws_s3_bucket.bucket.id}"
  key            = "base_cluster.yml"
  content_base64 = "${base64encode(data.template_file.base_cluster_yml.rendered)}"
}

resource "aws_iam_role" "rke" {
  name = "${var.name}-rke"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# Policy
resource "aws_iam_role_policy" "rke" {
  name = "${var.name}-rke"
  role = "${aws_iam_role.rke.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeTags",
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVolumes",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifyVolume",
        "ec2:AttachVolume",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteVolume",
        "ec2:DetachVolume",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DescribeVpcs",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:AttachLoadBalancerToSubnets",
        "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateLoadBalancerPolicy",
        "elasticloadbalancing:CreateLoadBalancerListeners",
        "elasticloadbalancing:ConfigureHealthCheck",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancerListeners",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DetachLoadBalancerFromSubnets",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeLoadBalancerPolicies",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
        "iam:CreateServiceLinkedRole",
        "kms:DescribeKey",
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "rke" {
  name = "${var.name}-rke"
  role = "${aws_iam_role.rke.name}"
}

# Launch Template
resource "aws_launch_template" "rke" {
  name_prefix                          = "${var.name}"
  image_id                             = "${data.aws_ami.rancheros.id}"
  instance_type                        = "${var.instance_type}"
  instance_initiated_shutdown_behavior = "terminate"
  key_name                             = "${aws_key_pair.rke.key_name}"
  user_data                            = "${base64encode(file("${path.module}/cloud-config.yaml"))}"
  ebs_optimized                        = true

  block_device_mappings = {
    device_name = "/dev/sda1"

    ebs = {
      volume_type = "gp2"
      volume_size = 50
    }
  }

  iam_instance_profile = {
    name = "${aws_iam_instance_profile.rke.name}"
  }

  network_interfaces = {
    associate_public_ip_address = true
    security_groups             = ["${aws_security_group.rke.id}"]
    delete_on_termination       = true
  }

  tag_specifications = {
    resource_type = "instance"

    tags = "${local.tags}"
  }
}

# (╯°□°)╯︵ ┻━┻ Why can't I just add rolling update policy with an asg resource?
resource "aws_cloudformation_stack" "rolling_update_asg" {
  name          = "${var.name}"
  template_body = "${file("${path.module}/cf-asg.yaml")}"

  parameters = {
    # A couple of resource Ids are passed in to link this to other TF objects.
    Bucket                = "${aws_s3_bucket.bucket.id}"
    BaseClusterId         = "${aws_s3_bucket_object.base_cluster_yml.id}"
    LambdaPermissionId    = "${aws_lambda_permission.rke.id}"
    LaunchTemplateId      = "${aws_launch_template.rke.id}"
    LaunchTemplateVersion = "${aws_launch_template.rke.latest_version}"
    LoadBalancerNames     = "${aws_elb.kubeapi.name}"
    MinSize               = 3
    MaxSize               = 4
    Name                  = "${var.name}"
    RoleARN               = "${aws_iam_role.publisher_role.arn}"
    SnsARN                = "${aws_sns_topic.rke.arn}"
    VPCZoneId             = "${join(",", data.aws_subnet_ids.available.ids)}"
    NotificationMetadata  = "{ \"lb\": \"https://${aws_route53_record.kubeapi.fqdn}:6443\" }"
  }
}
