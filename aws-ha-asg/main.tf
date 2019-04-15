provider "aws" {
  profile = "${var.aws_profile}"
  region  = "${var.aws_region}"
}

resource "aws_s3_bucket" "bucket" {
  bucket        = "${var.name}"
  acl           = "private"
  force_destroy = true
}

# Resources are orgainized in seperate files and "stages"
# Not exactly order, but more to give an idea of what should happen first.
# Stage 0
#  0-data.tf - Collect data about the environment
# Stage 1
#  1-elb.tf - Create kube-api ELB
#  1-ssh_key.tf - Generate SSH key and save to s3
#  1-sns.tf - Set up sns service to recieve autoscaling notifications
#  1-lambda.tf - Set up lambda to do the add/remove nodes with rke
# Stage 2 - Set up Nodes
#  2-nodes.tf - Set up cloudformation/ASG with rollingUpdates
# Stage 3 - Install Rancher
#  3-helm.tf - Install helm charts (ingress-nginx, external_dns, cert-manager, rancher)

