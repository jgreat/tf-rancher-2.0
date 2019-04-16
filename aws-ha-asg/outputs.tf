output "rancher_url" {
  value = "https://${var.name}.${var.domain}"
}

output "s3 bucket" {
  value = "s3://${aws_s3_bucket.bucket.id}"
}
