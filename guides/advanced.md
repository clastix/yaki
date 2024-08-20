# Advanced Usage
This guide will lead you through the process of creating an High Availability Kubernetes cluster using `yaki`.

## Requirements

Make sure your environment fulfills following requirements:

* A Linux workstation as bootstrap machine.
* A set of compatible Linux machines with `systemd` for control plane, datastore (`etcd`), and workers.
* An odd number (three recommended) of machines that will run `etcd` and other control plane services.
* For each `etcd` machine, an additional `sdb` disk of 10GB.
* For each `worker` machine, an additional `sdb` disk of 64GB.
* Full network connectivity between all machines in the cluster (public or private network is fine).
* Unique hostname, MAC address, and IP address for every machine.
* A virtual IP address in the same network to allow control plane load balancing.
* A second virtual IP address in the same network to allow workloads load balancing.
* Swap configuration. The default behavior of a `kubeadm` install was to fail to start if swap memory was detected.
* Must be run as the root user or through `sudo`.

## Prerequisites

The script expects some tools to be installed on your machines. It will fail if they are not found: `conntrack`, `socat`, `ip`, `iptables`, `modprobe`, `sysctl`, `systemctl`, `nsenter`, `ebtables`, `ethtool`, `wget`.

> Most of them should be already available in a bare Ubuntu installation.

## Procedure

  * [Prepare the bootstrap workspace](#prepare-the-bootstrap-workspace)
  * [Create the cluster](#create-the-cluster)
  * [Install addons](#install-addons)
  * [Cleanup](#cleanup)

## Prepare the bootstrap workspace

First, prepare the bootstrap workspace directory:

```bash
git clone https://github.com/clastix/yaki
cd guides
```

### Install kubectl
For the administration of the kubernetes cluster, install the `kubectl` utility on the local bootstrap machine.

Install `kubectl` on Linux

```bash
KUBECTL_VER=v1.30.2
KUBECTL_URL=https://dl.k8s.io/release
curl -LO ${KUBECTL_URL}/${KUBECTL_VER}/bin/linux/amd64/kubectl
sudo mv kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl
```

Install `kubectl` on OSX

```bash
KUBECTL_VER=v1.30.2
KUBECTL_URL=https://dl.k8s.io/release
curl -LO ${KUBECTL_URL}/${KUBECTL_VER}/bin/darwin/amd64/kubectl
sudo mv kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl
```

### Install etcdctl
For the administration of the `etcd` cluster, install the `etcdctl` utility on the local bootstrap machine.

Install `etcdctl` on Linux:

```bash
ETCD_VER=v3.5.6
ETCD_URL=https://storage.googleapis.com/etcd
curl -LO ${ETCD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz -d /tmp
sudo cp /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/etcdctl
```

Install `etcdctl` on OSX

```bash
ETCD_VER=v3.5.6
ETCD_URL=https://storage.googleapis.com/etcd
curl -LO ${ETCD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-darwin-amd64.zip
unzip etcd-${ETCD_VER}-darwin-amd64.zip -d /tmp
sudo cp /tmp/etcd-${ETCD_VER}-darwin-amd64/etcdctl /usr/local/bin/etcdctl
```

### Install Helm
For the administration of the additional components on the kubernetes cluster, download and install the `helm` on the local bootstrap machine.

Install `helm` on Linux

```bash
HELM_VER=v3.15.2
HELM_URL=https://get.helm.sh
curl -LO ${HELM_URL}/helm-${HELM_VER}-linux-amd64.tar.gz
tar xzvf helm-${HELM_VER}-linux-amd64.tar.gz -C /tmp
sudo cp /tmp/linux-amd64/helm /usr/local/bin/helm
```

Install `helm` on OSX

```bash
HELM_VER=v3.15.2
HELM_URL=https://get.helm.sh
curl -LO ${HELM_URL}/helm-${HELM_VER}-darwin-amd64.tar.gz
tar xzvf helm-${HELM_VER}-darwin-amd64.tar.gz -C /tmp
sudo cp /tmp/darwin-amd64/helm /usr/local/bin/helm
```

### Get the infrastucture
In this guide, we assume the infrastructure that will host the kubernetes cluster is already in place. If this is not the case, you can use any way to provision it, according to your environment and preferences. Throughout the instructions, shell variables are used to indicate values that you should adjust to your own environment.

```bash
source setup.env
```

### Ensure host access
The installer requires a user that has access to all hosts. In order to run the installer as a non-root user, first configure passwordless sudo rights each host:

Generate an SSH key on the host you run the installer on:

```bash
ssh-keygen -t rsa
```
> Do not use a password.

Distribute the key to the other cluster hosts.

Depending on your environment, use a bash loop:

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh-copy-id -i ~/.ssh/id_rsa.pub $HOST;
done
```

> Alternatively, inject the generated public key into machines metadata.

Confirm that you can access each host from bootstrap machine:

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t 'hostname';
done
```

## Create the cluster
To create an High Availability Kubernetes cluster, you first configure machines for storage and load balancing, then use `yaki` to create the cluster.

### Configure etcd disk layout
As per `etcd` [requirements](https://etcd.io/docs/v3.5/op-guide/hardware/#disks), back `etcd`’s storage with a SSD. A SSD usually provides lower write latencies and with less variance than a spinning disk, thus improving the stability and reliability of `etcd`.

For each `etcd` machine, we assume an additional `sdb` disk of 10GB:

```
$ lsblk
NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sda       8:0    0   16G  0 disk 
├─sda1    8:1    0 15.9G  0 part /
├─sda14   8:14   0    4M  0 part 
└─sda15   8:15   0  106M  0 part /boot/efi
sdb       8:16   0   10G  0 disk 
sr0      11:0    1    4M  0 rom  
```

Create partition, format, and mount the `etcd` disk, by running the script below from the bootstrap machine:

> If you already used the `etcd` disk on your machines, please make sure to wipe the partitions with `sudo wipefs --all --force /dev/sdb` before to attempt to recreate them.

```bash
for i in "${!ETCDHOSTS[@]}"; do
  HOST=${ETCDHOSTS[$i]}
  ssh ${USER}@${HOST} -t 'echo type=83 | sudo sfdisk -f -q /dev/sdb'
  ssh ${USER}@${HOST} -t 'sudo mkfs -F -q -t ext4 /dev/sdb1'
  ssh ${USER}@${HOST} -t 'sudo mkdir -p /var/lib/etcd'
  ssh ${USER}@${HOST} -t 'sudo e2label /dev/sdb1 ETCD'
  ssh ${USER}@${HOST} -t 'echo LABEL=ETCD /var/lib/etcd ext4 defaults 0 1 | sudo tee -a /etc/fstab'
  ssh ${USER}@${HOST} -t 'sudo mount -a'
  ssh ${USER}@${HOST} -t 'sudo lsblk -f'
done
```

### Configure persistent volumes disk layout
Persistent volumes are used to store workloads' data. The [Local Path Provisioner](https://github.com/rancher/local-path-provisioner) provides a way for the Kubernetes users to utilize the local storage in each worker node. Based on the user configuration, the Local Path Provisioner will create either `hostPath` persistent volume on the node automatically.

For each `worker` machine, we assume an additional `sdb` disk of 64GB:

```
$ lsblk
NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sda       8:0    0   16G  0 disk 
├─sda1    8:1    0 15.9G  0 part /
├─sda14   8:14   0    4M  0 part 
└─sda15   8:15   0  106M  0 part /boot/efi
sdb       8:16   0   64G  0 disk 
sr0      11:0    1    4M  0 rom  
```

Create partition, format, and mount the `localpath` disk, by running the script below from the bootstrap machine:

> If you already used the `localpath` disk on your machines, please make sure to wipe the partitions with `sudo wipefs --all --force /dev/sdb` before to attempt to recreate them.

```bash
for i in "${!WORKERS[@]}"; do
  HOST=${WORKERS[$i]}
  ssh ${USER}@${HOST} -t 'echo type=83 | sudo sfdisk -f -q /dev/sdb'
  ssh ${USER}@${HOST} -t 'sudo mkfs -F -q -t ext4 /dev/sdb1'
  ssh ${USER}@${HOST} -t 'sudo mkdir -p /var/data/local'
  ssh ${USER}@${HOST} -t 'sudo e2label /dev/sdb1 DATA'
  ssh ${USER}@${HOST} -t 'echo LABEL=DATA /var/data/local ext4 defaults 0 1 | sudo tee -a /etc/fstab'
  ssh ${USER}@${HOST} -t 'sudo mount -a'
  ssh ${USER}@${HOST} -t 'sudo lsblk -f'
done
```

### Setup keepalived
Setup `kubelived` (with `apt`) on control plane nodes to expose the `kube-apiserver` cluster endpoint: 

```bash
cat << EOF | tee master-keepalived.conf
# keepalived global configuration
global_defs {
    default_interface ${MASTER_IF} 
    enable_script_security 
}
vrrp_script apiserver {
    script   "/usr/bin/curl -s -k https://localhost:${MASTER_PORT}/healthz -o /dev/null"
    interval 20
    timeout  5
    rise     1
    fall     1
    user     root
}
vrrp_instance VI_1 {
    state BACKUP
    interface ${MASTER_IF}
    virtual_router_id 100
    priority 10${i}
    advert_int 20
    authentication {
    auth_type PASS
    auth_pass cGFzc3dvcmQ=
    }
    track_script {
    apiserver
    }     
    virtual_ipaddress {
        ${MASTER_VIP} label ${MASTER_IF}:VIP
    }
}
EOF
```

```bash
for i in "${!MASTERS[@]}"; do
MASTER=${MASTERS[$i]}
scp master-keepalived.conf ${USER}@${MASTER}:
ssh ${USER}@${MASTER} -t 'sudo apt update'
ssh ${USER}@${MASTER} -t 'sudo apt install -y keepalived'
ssh ${USER}@${MASTER} -t 'sudo chown -R root:root master-keepalived.conf'
ssh ${USER}@${MASTER} -t 'sudo mv master-keepalived.conf /etc/keepalived/keepalived.conf'
ssh ${USER}@${MASTER} -t 'sudo systemctl restart keepalived'
ssh ${USER}@${MASTER} -t 'sudo systemctl enable keepalived'
done
```

Setup `kubelived` (with `apt`) on worker nodes to expose workloads:

```bash
cat << EOF | tee worker-keepalived.conf
# keepalived global configuration
global_defs {
    default_interface ${WORKER_IF} 
    enable_script_security 
}
vrrp_script ingress {
    script   "/usr/bin/curl -s -k https://localhost -o /dev/null"
    interval 20
    timeout  5
    rise     1
    fall     1
    user     root
}
vrrp_instance VI_1 {
    state BACKUP
    interface ${WORKER_IF}
    virtual_router_id 100
    priority 10${i}
    advert_int 20
    authentication {
    auth_type PASS
    auth_pass cGFzc3dvcmQ=
    }
    track_script {
    ingress
    }     
    virtual_ipaddress {
        ${WORKER_VIP} label ${WORKER_IF}:VIP
    }
}
EOF
```

```bash
for i in "${!WORKERS[@]}"; do
WORKER=${WORKERS[$i]}
scp worker-keepalived.conf ${USER}@${WORKER}:
ssh ${USER}@${WORKER} -t 'sudo apt install -y keepalived'
ssh ${USER}@${WORKER} -t 'sudo chown -R root:root worker-keepalived.conf'
ssh ${USER}@${WORKER} -t 'sudo mv worker-keepalived.conf /etc/keepalived/keepalived.conf'
ssh ${USER}@${WORKER} -t 'sudo systemctl restart keepalived'
ssh ${USER}@${WORKER} -t 'sudo systemctl enable keepalived'
done
```


### Initialize the seed node

Create the `kubeadm-config.yaml` file in the local path:

```bash
cat > kubeadm-config.yaml <<EOF  
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token:
  ttl: 48h0m0s
  usages:
  - signing
  - authentication
localAPIEndpoint:
  advertiseAddress: "0.0.0.0"
  bindPort: ${MASTER_PORT}
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: ${CLUSTER_NAME}
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.k8s.io
networking:
  dnsDomain: cluster.local
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SVC_CIDR}
dns:
  imageRepository: registry.k8s.io/coredns
  imageTag: v1.9.3
controlPlaneEndpoint: "${MASTER_VIP}:${MASTER_PORT}"
etcd:
  local:
    dataDir: /var/lib/etcd/data
apiServer:
  certSANs:
  - localhost
  - ${MASTER_VIP}
  - ${CLUSTER_NAME}.${CLUSTER_DOMAIN}
scheduler:
  extraArgs:
    bind-address: "0.0.0.0" # required to expose metrics
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0" # required to expose metrics
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: "0.0.0.0" # required to expose metrics
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd  # tells kubelet about cgroup driver to use (required by containerd)
EOF
```

and copy it to the seed machine:

```bash
scp kubeadm-config.yaml ${USER}@${SEED}:
```

Initialize the seed machine:

```bash
ssh ${USER}@${SEED} 'sudo env KUBEADM_CONFIG=kubeadm-config.yaml bash -s' -- < yaki init
```

Once the installation completes, export the following envs from the output of the command above:

```bash
export JOIN_URL=<join-url>
export JOIN_TOKEN=<token>
export JOIN_TOKEN_CERT_KEY=<certificate-key>
export JOIN_TOKEN_CACERT_HASH=<discovery-token-ca-cert-hash>
```

Copy the kubeconfig file from the seed node to your workstation:

```bash
  ssh ${USER}@${SEED} -t 'sudo cp -i /etc/kubernetes/admin.conf .'
  ssh ${USER}@${SEED} -t 'sudo chown $(id -u):$(id -g) admin.conf'
  mkdir -p $HOME/.kube
  scp ${USER}@${SEED}:admin.conf $HOME/.kube/${CLUSTER_NAME}.kubeconfig
```

and check the status of the Kubernetes cluster

```bash
export KUBECONFIG=$HOME/.kube/${CLUSTER_NAME}.kubeconfig
kubectl cluster-info
```

Join the remaining control plane nodes:

```bash
MASTERS=(${MASTER1} ${MASTER2})
for i in "${!MASTERS[@]}"; do
  MASTER=${MASTERS[$i]}
  ssh ${USER}@${MASTER} 'sudo env JOIN_URL='${JOIN_URL}' env JOIN_TOKEN='${JOIN_TOKEN}' env JOIN_TOKEN_CERT_KEY='${JOIN_TOKEN_CERT_KEY}' env JOIN_TOKEN_CACERT_HASH='sha256:${JOIN_TOKEN_CACERT_HASH}' env JOIN_ASCP=1 bash -s' -- < yaki join;
done
```

Join all the worker nodes:

```bash
for i in "${!WORKERS[@]}"; do
  WORKER=${WORKERS[$i]}
  ssh ${USER}@${WORKER} 'sudo env JOIN_URL='${JOIN_URL}' env JOIN_TOKEN='${JOIN_TOKEN}' env JOIN_TOKEN_CACERT_HASH='sha256:${JOIN_TOKEN_CACERT_HASH}' bash -s' -- < yaki join;
done
```

Check the cluster has formed:

```bash
kubectl get nodes
```

Cluster nodes are still in a `NotReady` state because of the missing CNI component.

### Check the etcd datastore
To inspect and check the etcd datastore with `etcdctl` tool, retrieve the certificates:

```bash
ssh ${USER}@${SEED} -t 'sudo cp -i /etc/kubernetes/pki/etcd/ca.crt etcd-ca.crt'
ssh ${USER}@${SEED} -t 'sudo cp -i /etc/kubernetes/pki/etcd/healthcheck-client.crt etcd-client.crt'
ssh ${USER}@${SEED} -t 'sudo cp -i /etc/kubernetes/pki/etcd/healthcheck-client.key etcd-client.key'
ssh ${USER}@${SEED} -t 'sudo chown $(id -u):$(id -g) etcd-*'
mkdir -p $HOME/.etcd
scp ${USER}@${SEED}:etcd-* $HOME/.etcd/

export ETCDCTL_CACERT=$HOME/.etcd/etcd-ca.crt
export ETCDCTL_CERT=$HOME/.etcd/etcd-client.crt
export ETCDCTL_KEY=$HOME/.etcd/etcd-client.key
export ETCDCTL_ENDPOINTS=https://${ETCD0}:2379

etcdctl member list -w table
```

## Install addons

### Install the CNI
Install the CNI Calico plugin from the example manifest `calico.yaml`:

```bash
kubectl apply -f calico.yaml
```

And check all the nodes are now in `Ready` state

```bash
kubectl get nodes
```

### Install the Local Path Storage Provisioner
Install the Local Path Provisioner plugin from the example manifest `localpath.yaml`:

```bash
kubectl apply -f localpath.yaml
```

## Cleanup
For each machine, clean the installation by calling 'yaki' with the 'reset' command:

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} 'sudo bash -s' -- < yaki reset;
done
```

That's all folks!