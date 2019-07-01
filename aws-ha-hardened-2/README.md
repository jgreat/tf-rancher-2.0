# Pen-Test Environment

Sets up Rancher server as a (mostly) best-practices k8s cluster.

## Known Issues

* Doesn't create users (rancher2 TF provider missing this function)
* Doesn't add configure kube-scheduler for CIS best practice (rancher2 TF missing config block)

## Usage

Terraform 0.11
Update local vars for your environment.
Apply server directory first, then apply worker.

### Apply server

```plain
cd server
terraform init
terraform apply
...

cd ../worker
terraform init
terraform apply
```

## Destruction

Destroy worker first, then destroy server.
