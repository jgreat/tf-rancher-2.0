output "public_ips" {
  value = "${azurerm_public_ip.rancher.*.ip_address}"
}

output "private_ips" {
  value = "${azurerm_network_interface.rancher.*.private_ip_address}"
}

output "rancher_url" {
  value = "https://${var.rg}.${var.domain}"
}
