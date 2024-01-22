# Setup Kubernetes
This guide will lead you through the process of creating a basic Kubernetes setup.

It requires:

- (optional) a bootstrap node;
- an arbitrary number of (virtual) machines as nodes of the cluster.

Procedure:

  * [Prepare the bootstrap workspace](#prepare-the-bootstrap-workspace)
  * [Install Prerequisites](#install-prerequisites)
  * [Install Kubernetes](#install-kubernetes)
  * [Create the cluster](#create-the-cluster)
  * [Install addons](#install-addons)
  * [Cleanup](#cleanup)

## Prepare the bootstrap workspace
This guide is supposed to be run from a remote or local bootstrap machine:

First, prepare the workspace directory:

```bash
git clone https://github.com/clastix/yaki
cd yaki
```

### Install kubectl
For the administration of the kubernetes cluster, install the `kubectl` utility on the local bootstrap machine.

Install `kubectl` on Linux

```bash
KUBECTL_VER=v1.26.12
KUBECTL_URL=https://dl.k8s.io/release
curl -LO ${KUBECTL_URL}/${KUBECTL_VER}/bin/linux/amd64/kubectl
sudo mv kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl
```

Install `kubectl` on OSX

```bash
KUBECTL_VER=v1.26.1
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
ETCD_VER=v3.5.1
ETCD_URL=https://storage.googleapis.com/etcd
curl -LO ${ETCD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz -d /tmp
sudo cp /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/etcdctl
```

Install `etcdctl` on OSX

```bash
ETCD_VER=v3.5.1
ETCD_URL=https://storage.googleapis.com/etcd
curl -LO ${ETCD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-darwin-amd64.zip
unzip etcd-${ETCD_VER}-darwin-amd64.zip -d /tmp
sudo cp /tmp/etcd-${ETCD_VER}-darwin-amd64/etcdctl /usr/local/bin/etcdctl
```

### Install Helm
For the administration of the additional components on the kubernetes cluster, download and install the `helm` on the local bootstrap machine.

Install `helm` on Linux

```bash
HELM_VER=v3.9.2
HELM_URL=https://get.helm.sh
curl -LO ${HELM_URL}/helm-${HELM_VER}-linux-amd64.tar.gz
tar xzvf helm-${HELM_VER}-linux-amd64.tar.gz -C /tmp
sudo cp /tmp/linux-amd64/helm /usr/local/bin/helm
```

Install `helm` on OSX

```bash
HELM_VER=v3.9.2
HELM_URL=https://get.helm.sh
curl -LO ${HELM_URL}/helm-${HELM_VER}-darwin-amd64.tar.gz
tar xzvf helm-${HELM_VER}-darwin-amd64.tar.gz -C /tmp
sudo cp /tmp/darwin-amd64/helm /usr/local/bin/helm
```

### Get the infrastucture
In this guide, we assume the infrastructure that will host the kubernetes cluster is already in place. If this is not the case, you can use any way to provision it, according to your environment and preferences.

Throughout the instructions, shell variables are used to indicate values that you should adjust to your own environment.

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

## Install prerequisites

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
Setup `kubelived` on control plane nodes to expose the `kube-apiserver` cluster endpoint: 

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

Setup `kubelived` on worker nodes to expose workloads

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

## Install Kubernetes
Use `./yaki.sh setup` to prepare the machines and install Kubernetes components. Use environment variables to adjust the setup according to your needs:

```bash
    INSTALL_METHOD: The installation method to use: 'apt', 'tar', 'rpm' (TBD), or 'airgap' (TBD). Default is 'tar'
    CONTAINERD_VERSION: Version of container runtime containerd. Default is 'v1.7.12' (tar only)
    RUNC_VERSION: Version of runc to install. Default is 'v1.1.11' (tar only)
    CNI_VERSION: Version of CNI plugins to install. Default is 'v1.4.0' (tar only)
    CRICTL_VERSION: Version of crictl to install. Default is 'v1.29.0' (tar only)
    KUBERNETES_VERSION: Version of kubernetes to install. Default is 'v1.28.0'
    DEBUG: Set to 1 for more verbosity during script execution. Default is 0.
```

Choose between different methods of installation:

- `apt` based
- `rpm` based (not implemented)
- `tar` based (default)
- airgapped (not implemented)

### `apt` based
For Debian based distributions:

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t 'sudo env KUBERNETES_VERSION=v1.28.6 env INSTALL_METHOD=apt bash -s' -- < yaki.sh setup
done
```

### `tar` based
Install without a package manager:

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t 'sudo env KUBERNETES_VERSION=v1.28.6 env INSTALL_METHOD=tar bash -s' -- < yaki.sh setup
done
```

## Create the cluster
To create the Kubernetes cluster, you first initialize the seed machine with `yaki.sh init` command and then will join the remaining machines with `yaki.sh join` command.

Use environment variables to adjust the cluster formation according to your needs:

```bash
  KUBEADM_CONFIG: Path to the kubeadm config file to use. Default is not set.
  ADVERTISE_ADDRESS: Address to advertise for the api-server. Default is '0.0.0.0'
  BIND_PORT: Port to use for the api-server. Default is '6443'
  JOIN_TOKEN: Token to join the control-plane. Default is 'abcdef.1234567890abcdef'
  JOIN_TOKEN_CACERT_HASH: Token Certificate Authority hash to join the control-plane. Default is not set.
  JOIN_TOKEN_CERT_KEY: Token Certificate Key to join the control-plane, cp node will not join if not passed. Default is '78102ac003f419c81bd4e1b23870227b1d98300b8fcc50e859ede1203d8fb2ed'
  JOIN_URL: URL to join the control-plane, node will not join if not passed. Default is not set.
    echo "  JOIN_AS_CP: Switch to join either as control plane or worker. Default is 0.
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
ssh ${USER}@${SEED} 'sudo env KUBEADM_CONFIG=kubeadm-config.yaml bash -s' -- < yaki.sh init
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
  ssh ${USER}@${MASTER} 'sudo env JOIN_URL='${JOIN_URL}' env JOIN_TOKEN='${JOIN_TOKEN}' env JOIN_TOKEN_CERT_KEY='${JOIN_TOKEN_CERT_KEY}' env JOIN_TOKEN_CACERT_HASH='${JOIN_TOKEN_CACERT_HASH}' env JOIN_AS_CP=1 bash -s' -- < yaki.sh join;
done
```

Join all the worker nodes:

```bash
for i in "${!WORKERS[@]}"; do
  WORKER=${WORKERS[$i]}
  ssh ${USER}@${WORKER} 'sudo env JOIN_URL='${JOIN_URL}' env JOIN_TOKEN='${JOIN_TOKEN}' env JOIN_TOKEN_CACERT_HASH='${JOIN_TOKEN_CACERT_HASH}' bash -s' -- < yaki.sh join;
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
Install the CNI Calico plugin:

```bash
kubectl apply -f addons/calico.yaml
```

And check all the nodes are now in `Ready` state

```bash
kubectl get nodes
```

### Install the Local Path Storage Provisioner
Install the Local Path Provisioner plugin:

```bash
kubectl apply -f addons/localpath.yaml
```

## Cleanup
For each node, login and clean it

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t 'sudo kubeadm reset -f';
  ssh ${USER}@${HOST} -t 'sudo rm -rf /etc/cni/net.d';
  ssh ${USER}@${HOST} -t 'sudo systemctl reboot';
done
```