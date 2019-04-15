data "aws_s3_bucket_object" "kubeconfig" {
  bucket = "${lookup(aws_cloudformation_stack.rolling_update_asg.outputs, "bucket")}"
  key    = "vars.json"
}

data "external" "kubeconfig" {
  program = ["echo", "${data.aws_s3_bucket_object.kubeconfig.body}"]
}

# output "body_host" {
#   value = "${data.external.kubeconfig.result["host"]}"
# }

provider "helm" {
  namespace       = "kube-system"
  service_account = "tiller"

  kubernetes = {
    host                   = "${data.external.kubeconfig.result["host"]}"
    username               = "${data.external.kubeconfig.result["username"]}"
    client_certificate     = "${base64decode(data.external.kubeconfig.result["client_certificate_data"])}"
    client_key             = "${base64decode(data.external.kubeconfig.result["client_key_data"])}"
    cluster_ca_certificate = "${base64decode(data.external.kubeconfig.result["certificate_authority_data"])}"
  }
}

data "helm_repository" "rancher" {
  name = "rancher-stable"
  url  = "https://releases.rancher.com/server-charts/stable/"
}

# ### Charts need to be chained to asg somehow so they get destroyed first
resource "helm_release" "nginx_ingress" {
  name      = "nginx-ingress"
  chart     = "stable/nginx-ingress"
  namespace = "ingress-nginx"

  set = {
    name  = "controller.publishService.enabled"
    value = "true"
  }

  set = {
    name  = "controller.replicaCount"
    value = "2"
  }

  # probably should set controller affinity.

  # Bogus set to link togeather resources for proper tear down
  set = {
    name  = "tf_link"
    value = "${aws_cloudformation_stack.rolling_update_asg.outputs["id"]}"
  }
  depends_on = ["data.external.kubeconfig"]
}

resource "helm_release" "external_dns" {
  name      = "external-dns"
  chart     = "stable/external-dns"
  namespace = "kube-system"

  set = {
    name  = "rbac.create"
    value = "true"
  }

  set = {
    name  = "txtOwnerId"
    value = "${var.name}"
  }

  set = {
    name  = "provider"
    value = "aws"
  }

  set = {
    name  = "sources[0]"
    value = "ingress"
  }

  set = {
    name  = "domainFilters[0]"
    value = "${var.domain}"
  }

  set = {
    name  = "policy"
    value = "sync"
  }

  # Bogus set to link togeather resources for proper tear down
  set = {
    name  = "tf_link"
    value = "${helm_release.nginx_ingress.name}"
  }
}

resource "helm_release" "cert_manager" {
  version   = "v0.5.2"
  name      = "cert-manager"
  chart     = "stable/cert-manager"
  namespace = "kube-system"

  # Bogus set to link togeather resources for proper tear down
  set = {
    name  = "tf_link"
    value = "${helm_release.nginx_ingress.name}"
  }
}

resource "helm_release" "rancher" {
  depends_on = ["helm_release.cert_manager"]
  version    = "${var.rancher_version}"
  name       = "rancher"
  repository = "${data.helm_repository.rancher.metadata.0.name}"
  chart      = "rancher"
  namespace  = "cattle-system"

  set = {
    name  = "hostname"
    value = "${var.name}.${var.domain}"
  }

  set = {
    name  = "ingress.tls.source"
    value = "letsEncrypt"
  }

  set = {
    name  = "letsEncrypt.email"
    value = "none@none.com"
  }

  # Bogus set to link togeather resources for proper tear down
  set = {
    name  = "tf_link_1"
    value = "${helm_release.cert_manager.name}"
  }

  set = {
    name  = "tf_link_2"
    value = "${helm_release.external_dns.name}"
  }
}
