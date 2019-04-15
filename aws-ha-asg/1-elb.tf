resource "aws_security_group" "kubeapi" {
  name   = "${var.name}-kubeapi"
  vpc_id = "${data.aws_vpc.default.id}"

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

  tags = {
    Name = "${var.name}-kubeapi"
  }
}

# kube-api elb
resource "aws_elb" "kubeapi" {
  name            = "${var.name}-kubeapi"
  subnets         = ["${data.aws_subnet_ids.available.ids}"]
  security_groups = ["${aws_security_group.kubeapi.id}"]

  listener = {
    instance_port     = 6443
    instance_protocol = "tcp"
    lb_port           = 6443
    lb_protocol       = "tcp"
  }

  health_check = {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "tcp:6443"
    interval            = 5
  }

  idle_timeout = 1800

  tags = {
    Name = "${var.name}-kubeapi"
  }
}

# route53 to elb
resource "aws_route53_record" "kubeapi" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${var.name}-kubeapi"
  type    = "A"

  alias {
    name                   = "${aws_elb.kubeapi.dns_name}"
    zone_id                = "${aws_elb.kubeapi.zone_id}"
    evaluate_target_health = true
  }
}
