# Create RKE node definitions
data "template_file" "rke_node" {
  count = "${var.vm_count}"

  template = <<EON
- address: $${public_ip}
  internal_address: $${private_ip}
  user: rancher
  role: [ "controlplane", "etcd", "worker" ]
EON

  vars {
    public_ip  = "${element(azurerm_public_ip.rancher.*.ip_address, count.index)}"
    private_ip = "${element(azurerm_network_interface.rancher.*.private_ip_address, count.index)}"
  }
}

# #Create RKE config
data "template_file" "rke" {
  template = <<EOF
nodes: 
$${nodes}
EOF

  vars {
    nodes = "${join("\n", data.template_file.rke_node.*.rendered)}"
  }
}

# Render RKE config file.
resource "local_file" "rke" {
  content  = "${data.template_file.rke.rendered}"
  filename = "${path.module}/outputs/cluster.yml"

  provisioner "local-exec" {
    when    = "destroy"
    command = "rm -f ${path.module}/kube_config_cluster.yml ${path.module}/cluster.rkestate"
  }
}
