resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

# Uncomment to save keys localy
# resource "local_file" "private_key" {
#   sensitive_content = "${tls_private_key.ssh.private_key_pem}"
#   filename          = "${path.module}/outputs/id_rsa"
# }

# resource "local_file" "public_key" {
#   content  = "${tls_private_key.ssh.public_key_openssh}"
#   filename = "${path.module}/outputs/id_rsa.pub"
# }

resource "aws_key_pair" "rke" {
  key_name   = "${var.name}"
  public_key = "${tls_private_key.ssh.public_key_openssh}"
}

resource "aws_s3_bucket_object" "private_key" {
  bucket         = "${aws_s3_bucket.bucket.id}"
  key            = "id_rsa"
  content_base64 = "${base64encode(tls_private_key.ssh.private_key_pem)}"
}
