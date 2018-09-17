# Install

## Build Nodes

This will create 3 nodes ready for RKE, a RKE `cluster.yml` and a node with a private docker registry ready to go. The 3 RKE nodes have security groups that prevent egress traffic from the internet. Only 80/443 from the ELB and SSH to the cidr range specified as the `my_ip_cidr` variable.

```plain
terraform apply
...
Outputs:

rancher_address = [
    18.222.121.187,
    18.220.193.254,
    13.59.83.89
]
rancher_internal_address = [
    172.31.7.22,
    172.31.13.132,
    172.31.3.216
]
rancher_registry_address = 18.222.61.179
rancher_registry_internal_address = 172.31.1.242
rancher_url = https://jgreat-ag-1.rancher.space
registry_password = @DC##ZB_9iR!<UuZkrcz
registry_url = jgreat-ag-1-registry.rancher.space
registry_user = rancher
```

## Gather Images

There are 4 sources to gather images from to populate your private Docker registry for the Rancher server install.

1. RKE  
    A list of RKE images required by can be compiled by running.
    ```plain
    rke config --system-images
    ```
1. Rancher `rancher-images.txt`  
    Rancher has additional images it uses when installing clusters. These images are listed in the `rancher-images.txt`. You can find this on the [rancher/rancher](https://github.com/rancher/rancher/releases) GitHub Releases page.  

1. Helm `tiller` image  
    You can discover the `tiller` image compatible with your installed version of `helm` with this command.
    ```plain
    helm init --dry-run --debug | grep image: | awk '{print $2}'
    ```
1. Cert-Manager Image
    Rancher uses the Cert-Manger project to issue self-singed certificates for Rancher GUI/Agent access. You can inspect the `cert-manager` chart values.yaml to find the latest image and tag.
    ```plain
    helm inspect values stable/cert-manager
    ...
    image:
      repository: quay.io/jetstack/cert-manager-controller
      tag: v0.4.1
    ...
    ```

This shell script can be used from a system with internet access to compile the images required by the latest Rancher release and write them to `images.txt` in the local directory.

_compile-images.sh_

```bash
#!/bin/bash
set -e

# Collect images for Air Gap/Private Registry install
# Requires:
#   rke - https://rancher.com/docs/rke/v0.1.x/en/installation/
#   helm - https://docs.helm.sh/using_helm/#installing-helm
#   curl
#   jq

echo "RKE Images"
rke config --system-images 2>/dev/null > tmp-images.txt

echo "Helm Tiller Image"
helm init --dry-run --debug | grep image: | awk '{print $2}' >> tmp-images.txt

echo "Rancher Images"
latest_url=$(curl -sS "https://api.github.com/repos/rancher/rancher/releases/latest" | jq -r '.assets[]|select(.name=="rancher-images.txt")|.browser_download_url')
curl -sSL ${latest_url} >> tmp-images.txt

echo "Cert-Manager Image"
cm_repo=$(helm inspect values stable/cert-manager | grep repository: | awk '{print $2}')
cm_tag=$(helm inspect values stable/cert-manager | grep tag: | awk '{print $2}')
echo "${cm_repo}:${cm_tag}" >> tmp-images.txt

echo "Sort and uniq the images list"
cat tmp-images.txt | sort -u | uniq > images.txt

# cleanup tmp file
rm tmp-images.txt
```

## Populate the Registry

Each image in the list will need to be pulled from public registries, tagged with your private registry url/path and pushed up to your private registry.

1. Pull Images
    ```plain
    docker pull rancher/coreos-etcd:v3.1.12
    ```  

1. Tag Images
    ```plain
    docker tag rancher/coreos-etcd:v3.1.12 my_registry.example.com/rancher/coreos-etcd:v3.1.12
    ```  
1. Push Images
    ```plain
    docker push my_registry.example.com/rancher/coreos-etcd:v3.1.12
    ```

This shell script can be used with a list of images (`images.txt`) to populate the private registry. To use this script the system will need access to both the internet and the private registry.

_populate-images.sh_

```bash
#!/bin/bash

# Usage:
# ./populate-images.sh --registry my_registry.example.com --images ./images.txt

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -r|--registry)
    reg="$2"
    shift # past argument
    shift # past value
    ;;
    -i|--images)
    images="$2"
    shift
    shift
    ;;
esac
done

if [[ -z $reg ]]; then
    echo "-r|--registry is required"
    exit 1
fi

if [[ -z $images ]]; then
    echo "-i|--images file is required"
    exit 1
fi

echo "Log into Docker registry ${reg}"
docker login ${reg}

for i in $(cat ${images}); do
    docker pull ${i}
    docker tag ${i} ${reg}/${i}
    docker push ${reg}/${i}
done
```

## Run RKE with Private Registry Options

Run `rke` pointing at the the nodes you created and include the `private_registries:` block. Set `is_default: true` for the registry that you pushed the images to.

_cluster.yml_

```yaml
nodes:
- address: 18.222.121.187
  internal_address: 172.31.7.22
  user: rancher
  role: [ "controlplane", "etcd", "worker" ]
  ssh_key_file: /home/jgreat/.ssh/id_rsa

- address: 18.220.193.254
  internal_address: 172.31.13.132
  user: rancher
  role: [ "controlplane", "etcd", "worker" ]
  ssh_key_file: /home/jgreat/.ssh/id_rsa

- address: 13.59.83.89
  internal_address: 172.31.3.216
  user: rancher
  role: [ "controlplane", "etcd", "worker" ]
  ssh_key_file: /home/jgreat/.ssh/id_rsa


private_registries:
- url: my_registry.example.com
  user: rancher
  password: "*********"
  is_default: true
```

Run RKE

```
rke up
```

## Install Helm (tiller)

The `tiller` serviceAccount that the tiller deployment uses will need credentials for the registry. Set up the serviceAccount and RBAC permissions as normal, then patch the service account to add the credentials.

```
kubectl -n kube-system create serviceaccount tiller
kubectl create clusterrolebinding tiller \
  --clusterrole cluster-admin \
  --serviceaccount=kube-system:tiller
```

### Initialize Helm

Initialize Helm with the `tiller` image in your private registry.

```
helm init --service-account tiller \
--tiller-image jgreat-ag-1-registry.rancher.space/gcr.io/kubernetes-helm/tiller:v2.10.0
```

## Install Rancher

### Install Cert-Manager

```
helm install stable/cert-manager --name cert-manager --namespace kube-system \
--set image.repository=jgreat-ag-1-registry.rancher.space/quay.io/jetstack/cert-manager-controller
```

### Install Rancher

Install Rancher setting the image source and imagePullSecrets options.

```plain
helm install rancher-stable/rancher --name rancher --namespace cattle-system \
--set hostname=jgreat-ag-1.rancher.space \
--set rancherImage=jgreat-ag-1-registry.rancher.space/rancher/rancher
```


`CATTLE_SYSTEM_DEFAULT_REGISTRY`