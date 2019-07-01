output "worker_addresses" {
  value = "${aws_instance.rancher_worker.*.public_ip}"
}
output "controlplane_addresses" {
  value = "${aws_instance.rancher_controlplane.*.public_ip}"
}
