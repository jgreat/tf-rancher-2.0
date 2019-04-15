# Notification Topic
resource "aws_sns_topic" "rke" {
  name = "${var.name}"
}

# SNS
# Role
resource "aws_iam_role" "publisher_role" {
  name = "${var.name}-publisher-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [ {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "autoscaling.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
  } ]
}
EOF
}

# Policy
data "template_file" "publisher_policy" {
  template = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [ {
      "Effect": "Allow",
      "Resource": "$${sns_id}",
      "Action": [
        "sns:Publish"
      ]
  } ]
}
EOF

  vars = {
    sns_id = "${aws_sns_topic.rke.id}"
  }
}

resource "aws_iam_role_policy" "publisher_policy" {
  name   = "${var.name}-publisher-policy"
  role   = "${aws_iam_role.publisher_role.id}"
  policy = "${data.template_file.publisher_policy.rendered}"
}
