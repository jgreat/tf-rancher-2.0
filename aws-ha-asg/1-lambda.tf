##### Lambda
# Role
resource "aws_iam_role" "lambda_role" {
  name = "${var.name}-lambda-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [ {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
  } ]
}
EOF
}

# Policy
data "template_file" "lambda_policy" {
  template = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": "*",
      "Action": [
          "ec2:DescribeInstances",
          "autoscaling:CompleteLifecycleAction"
      ]
    },
    { "Effect": "Allow",
      "Resource": "$${s3_bucket_id}",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
    },
    { "Effect": "Allow",
      "Resource": "$${s3_bucket_id}/*",
      "Action": [
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ]
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*",
      "Effect": "Allow"
    }
  ]
}
EOF

  vars = {
    s3_bucket_id = "${aws_s3_bucket.bucket.arn}"
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.name}-lambda-policy"
  role = "${aws_iam_role.lambda_role.id}"

  policy = "${data.template_file.lambda_policy.rendered}"
}

resource "aws_lambda_function" "rke" {
  description      = "Lambda to manage rke cluster"
  function_name    = "${var.name}"
  filename         = "${path.module}/lambda/rke.zip"
  role             = "${aws_iam_role.lambda_role.arn}"
  handler          = "lambda_function.lambda_handler"
  source_code_hash = "${base64sha256(file("${path.module}/lambda/rke.zip"))}"
  runtime          = "python3.6"
  timeout          = 600
  memory_size      = 256

  environment = {
    variables = {
      RKE_VERSION = "${var.rke_version}"
      S3_BUCKET   = "${aws_s3_bucket.bucket.id}"
    }
  }
}

resource "aws_sns_topic_subscription" "rke" {
  topic_arn = "${aws_sns_topic.rke.arn}"
  protocol  = "lambda"
  endpoint  = "${aws_lambda_function.rke.arn}"
}

resource "aws_lambda_permission" "rke" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.rke.arn}"
  principal     = "sns.amazonaws.com"
  source_arn    = "${aws_sns_topic.rke.arn}"
}
