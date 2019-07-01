data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "available" {
  vpc_id = "${data.aws_vpc.default.id}"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu-minimal/images/*/ubuntu-bionic-18.04-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "terraform_remote_state" "rancher" {
  backend = "s3"
  config = {
    bucket         = "tf-states"
    key            = "aws-ha-hardened-2/rancher_server.tfstate"
    region         = "us-west-2"
    dynamodb_table = "tf-state-lock"
  }
}
