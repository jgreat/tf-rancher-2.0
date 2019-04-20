# Need load-balancer
resource "azurerm_public_ip" "lb" {
  name                = "${var.rg}-lb-pip"
  location            = "${azurerm_resource_group.rancher.location}"
  resource_group_name = "${azurerm_resource_group.rancher.name}"
  allocation_method   = "Static"
}

resource "azurerm_lb" "rancher" {
  name                = "${var.rg}-lb"
  location            = "${azurerm_resource_group.rancher.location}"
  resource_group_name = "${azurerm_resource_group.rancher.name}"

  frontend_ip_configuration = {
    name                 = "${var.rg}-lb-fe"
    public_ip_address_id = "${azurerm_public_ip.lb.id}"
  }
}

resource "azurerm_lb_backend_address_pool" "rancher" {
  name                = "${var.rg}-lb-be-pool"
  resource_group_name = "${azurerm_resource_group.rancher.name}"
  loadbalancer_id     = "${azurerm_lb.rancher.id}"
}

resource "azurerm_lb_probe" "rancher" {
  name                = "${var.rg}-tcp-443-probe"
  resource_group_name = "${azurerm_resource_group.rancher.name}"
  loadbalancer_id     = "${azurerm_lb.rancher.id}"
  protocol            = "Tcp"
  port                = 443
  interval_in_seconds = 5
}

resource "azurerm_lb_rule" "tcp-80" {
  name                           = "lb-rule-tcp-80"
  resource_group_name            = "${azurerm_resource_group.rancher.name}"
  loadbalancer_id                = "${azurerm_lb.rancher.id}"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "${var.rg}-lb-fe"
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.rancher.id}"
  probe_id                       = "${azurerm_lb_probe.rancher.id}"
}

resource "azurerm_lb_rule" "tcp-443" {
  name                           = "lb-rule-tcp-443"
  resource_group_name            = "${azurerm_resource_group.rancher.name}"
  loadbalancer_id                = "${azurerm_lb.rancher.id}"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "${var.rg}-lb-fe"
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.rancher.id}"
  probe_id                       = "${azurerm_lb_probe.rancher.id}"
}

resource "azurerm_network_interface_backend_address_pool_association" "rancher" {
  count                   = "${var.vm_count}"
  network_interface_id    = "${element(azurerm_network_interface.rancher.*.id, count.index)}"
  ip_configuration_name   = "ip-configuration-1"
  backend_address_pool_id = "${azurerm_lb_backend_address_pool.rancher.id}"
}

resource "azurerm_dns_a_record" "lb" {
  name                = "${var.rg}"
  zone_name           = "${var.domain}"
  resource_group_name = "${var.dns_zone_rg}"
  ttl                 = 60
  records             = ["${azurerm_public_ip.lb.ip_address}"]
}
