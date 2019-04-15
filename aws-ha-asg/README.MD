# Manage RKE/Rancher on AWS ASGs with Lambda

>**Disclaimer:** This is example-proof-of-concept code.  This may or may not work out of the box for you.  It has not been designed to take in account all possible variations of AWS implementations.  Unforseen situations could arise in data loss, use with caution, take backups, do not apply while driving, YMMV...  
>  
>This example creates IAM policies and roles, uses public IP addresses and public AMI images. This really should be fine, but may not be appropriate for your security policies.

This terraform example sets up an Auto Scaling Group with a RollingUpdate policy for managing RKE nodes. ASG will send events to an SNS queue that triggers Lambda runs to add/remove nodes from the cluster. The lambda maintains lock files, rke state, kubeconfig, ssh keys, rke snapshots in an s3 bucket.

## Requirements

Installed locally:

* Terraform 0.11.13+
* `helm`
* `kubectl`
* `awscli`

AWS Access:

* IAM
* Route53
* EC2
* SNS
* S3
* Lambda
* VPC
* Probably something I forgot.

## Running

Create a `terraform.tfvars` files and populate some basic variables.

```terraform
# aws cli profile
aws_profile = "default"

# existing route53 zone
domain = "my.domain.com"

# rancher server name and resource prefix
name = "rancher-asg"

# From rancher-stable helm repo
rancher_version = "2.1.8"

# rke releases
rke_version = "v0.2.1"

# RancherOS release (ami)
ros_version = "v1.5.1-hvm-1"
```

Run terraform

```plain
terraform init
terrafrom apply
```

* Resources will be named or prefixed with `name`
* The Rancher hostname will be `name.domain`

## Updates

Updating the `ros_version` will trigger the ASG rolling update.

1. New node created (4 nodes)
1. Lambda triggered with `add_node` event
    * Wait for instance up
    * Wait for Docker ready
    * Wait for and Set Lock
    * Pull files from S3
    * Take `rke` snapshot and save to s3
    * `rke up`
    * Save state and creds to s3
    * Remove Lock
    * Send LifecycleComplete to ASG
1. Remove old node (3 nodes)
1. Lambda triggered with `remove_node` event
    * See above tasks
1. Rinse and Repeat

Updating the `rancher_version` will trigger a helm upgrade for the rancher chart.

Updating the `rke_version` will not trigger an ASG rolling update with this project.  Update `rke` in conjunction with an OS upgrade.

### Percautions

* The lambda creates a lock file when starting the update process so only one node will update at a time.
* `rke` snapshots of the `etcd` db are created and uploaded to s3 before add/remove steps.

### Monitoring the process

You can follow the the Lambda as it runs in CloudWatch Log Groups under `/aws/lambda/<name>`

## Were are all the files?

This terraform creates an s3 bucket for storage of state and credentials.  `s3://<name>`

## Network

We use the "default" VPC and Subnets in the region the ASGs are created in.

### What Terraform Creates

Terraform sets up a dns entry and elb in front of the ASG to route kube-api traffic into the node. The Lambda script updates the generated `kube_config_cluster.yml` credentials file with the elb dns endpoint.

```plain
    route53 dns
         |
kube-api (tcp:6443) elb
        /|\
        asg
   node node node
```

### What Kubernetes Creates

The ASG nodes are set up with appropriate IAM permissions to use the built in `cloud-provider` to automatically manage external resources (ELB, Route53 DNS, EBS storage). We take advantage of that to wire up the Rancher management instance.

`nginx-ingress` chart is used with a `LoadBalancer` type `Service`. This automatically creates an ELB listening on tcp:80/tcp:443 and forwards the connections back to the appropriate nodes.

`external-dns` monitors the `ingress` definitions and automatically creates Route53 DNS entries for hostnames that are defined.

`cert-manager` monitors the `ingress` definitions and is used to automatically issue and maintain a SSL certificate from LetsEncrypt.

The rancher helm chart creates an `ingress` with a hostname and cert-manager annotations defined.

```plain
        external-dns (Route53)
                 |
    nginx-ingress (LoadBalancer) ELB
                /|\
        node    node    node
       rancher rancher rancher
```
