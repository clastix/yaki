# Advanced Usage
This guide will lead you through the process of creating an High Availability Kubernetes cluster using `yaki`.

The control plane of an High Availability cluster is reached through a virtual IP address that floats across the control plane nodes. This guide covers two alternative ways to provide that virtual IP: `keepalived` and `kube-vip`. The steps are identical up to the disk layout configuration, then the guide forks into two paths: pick one, follow it until the cluster is formed, and resume with the common steps that close the guide.

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

If you plan to follow the `kube-vip` path, the bootstrap machine also needs `curl` and `jq` to resolve the latest `kube-vip` release.

## Procedure

  * [Prepare the bootstrap workspace](#prepare-the-bootstrap-workspace)
  * [Create the cluster](#create-the-cluster)
    * [Configure etcd disk layout](#configure-etcd-disk-layout)
    * [Configure persistent volumes disk layout](#configure-persistent-volumes-disk-layout)
    * [Choose the load balancing strategy](#choose-the-load-balancing-strategy)
  * [Path A: cluster with keepalived](#path-a-cluster-with-keepalived)
  * [Path B: cluster with kube-vip](#path-b-cluster-with-kube-vip)
  * [Check the etcd datastore](#check-the-etcd-datastore)
  * [Install addons](#install-addons)
  * [Cleanup](#cleanup)

## Prepare the bootstrap workspace

First, prepare the bootstrap workspace directory:

```bash
git clone https://github.com/clastix/yaki
cd yaki/guides
```

### Install kubectl
For the administration of the kubernetes cluster, install the `kubectl` utility on the local bootstrap machine.

Install `kubectl` on Linux

```bash
KUBECTL_VER=v1.36.2
KUBECTL_URL=https://dl.k8s.io/release
curl -LO ${KUBECTL_URL}/${KUBECTL_VER}/bin/linux/amd64/kubectl
sudo mv kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl
```

Install `kubectl` on OSX

```bash
KUBECTL_VER=v1.36.2
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
ETCD_VER=v3.5.13
ETCD_URL=https://storage.googleapis.com/etcd
curl -LO ${ETCD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp
sudo cp /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/etcdctl
```

Install `etcdctl` on OSX

```bash
ETCD_VER=v3.5.13
ETCD_URL=https://storage.googleapis.com/etcd
curl -LO ${ETCD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-darwin-amd64.zip
unzip etcd-${ETCD_VER}-darwin-amd64.zip -C /tmp
sudo cp /tmp/etcd-${ETCD_VER}-darwin-amd64/etcdctl /usr/local/bin/etcdctl
```

### Install Helm
For the administration of the additional components on the kubernetes cluster, download and install the `helm` on the local bootstrap machine.

Install `helm` on Linux

```bash
HELM_VER=v4.2.2
HELM_URL=https://get.helm.sh
curl -LO ${HELM_URL}/helm-${HELM_VER}-linux-amd64.tar.gz
tar xzvf helm-${HELM_VER}-linux-amd64.tar.gz -C /tmp
sudo cp /tmp/linux-amd64/helm /usr/local/bin/helm
```

Install `helm` on OSX

```bash
HELM_VER=v4.2.2
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
The installer requires a user that has access to all hosts. In order to run the installer as a non-root user, first configure passwordless sudo rights each host.

After that, generate an SSH key on the host you run the installer on:

```bash
ssh-keygen -t rsa
```
> Do not use a key passphrase.

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

> If you already used the `etcd` disk on your machines, please make sure to unmount the `etcd` directory from the disk with `sudo umount /var/lib/etcd` and to wipe the partitions with `sudo wipefs --all --force /dev/sdb` before to attempt to recreate them.

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

> If you already used the `localpath` disk on your machines, please make sure to unmount the `etcd` directory from the disk with `sudo umount /var/lib/etcd` and to wipe the partitions with `sudo wipefs --all --force /dev/sdb` before to attempt to recreate them.

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

### Choose the load balancing strategy
The `kube-apiserver` cluster endpoint, `${MASTER_VIP}:${MASTER_PORT}`, must be served by a virtual IP address that follows a healthy control plane node. Choose one of the two paths below.

| | **[Path A: keepalived](#path-a-cluster-with-keepalived)** | **[Path B: kube-vip](#path-b-cluster-with-kube-vip)** |
|---|---|---|
| Runs as | `systemd` service on the host, installed with `apt` | static pod managed by the `kubelet` |
| VIP mechanism | VRRP | ARP (or BGP) with leader election through the Kubernetes API |
| Health check | `curl` on the local `/healthz` endpoint | leader election on the API server |
| Bootstrap | VIP is already up before `kubeadm init` | VIP must be attached to the seed node by hand, then removed |


**keepalived — pros and cons**

* Independent of Kubernetes: the VIP is up before the cluster exists and survives a control plane outage, so `kubeadm init` needs no workaround.
* Well known, highly scriptable through 'script' section, and reusable as-is for the workload virtual IP on the worker nodes.
* But: it is an extra host-level package and configuration file per node, managed outside Kubernetes and prone to drift.
* But: it requires VRRP traffic to be allowed on the network, and a `virtual_router_id` that does not collide with other VRRP groups in the same L2 domain.

**kube-vip — pros and cons**

* Lives inside the cluster: no host packages, and upgrading means editing a static pod manifest.
* Leader election through the Kubernetes API, and support for BGP where ARP is not an option.
* It can also serve `Service` resources of type `LoadBalancer` when paired with the [kube-vip cloud provider](https://kube-vip.io/docs/usage/cloud-provider/), removing the need for a separate workload virtual IP.
* But: there is a chicken-and-egg problem at bootstrap. The VIP has to be assigned manually to the seed node interface before `kubeadm init` and removed right after for the purpose of _this_ guide.
* But: the static pod manifest has to be copied to every control plane node by hand, and the VIP depends on a working `kubelet` and a reachable API server.

Both paths use ARP/VRRP and therefore require all control plane nodes to sit in the same L2 network as the virtual IP.

---

## Path A: cluster with keepalived

  * [Setup keepalived](#setup-keepalived)
  * [Initialize the seed node](#initialize-the-seed-node)
  * [Join the other nodes](#join-the-other-nodes)

then continue with the [common steps](#check-the-etcd-datastore).

### Setup keepalived
Setup `keepalived` (with `apt`) on control plane nodes to expose the `kube-apiserver` cluster endpoint: 

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

Setup `keepalived` (with `apt`) on worker nodes to expose workloads:

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
  imageTag: ${COREDNS_VERSION} # Please make sure that this version is compliant with your cluster setup (see setup.env file in the repo)
controlPlaneEndpoint: "${MASTER_VIP}:${MASTER_PORT}"
kubernetesVersion: "${CLUSTER_VERSION}"
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

### Join the other nodes

Join the remaining control plane nodes:

```bash
MASTERS=(${MASTER1} ${MASTER2})
for i in "${!MASTERS[@]}"; do
  MASTER=${MASTERS[$i]}
  ssh ${USER}@${MASTER} 'sudo env JOIN_URL='${JOIN_URL}' env JOIN_TOKEN='${JOIN_TOKEN}' env JOIN_TOKEN_CERT_KEY='${JOIN_TOKEN_CERT_KEY}' env JOIN_TOKEN_CACERT_HASH='sha256:${JOIN_TOKEN_CACERT_HASH}' env JOIN_ASCP=true bash -s' -- < yaki join;
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

The cluster is now formed. Continue with [Check the etcd datastore](#check-the-etcd-datastore) and [Install addons](#install-addons), which are common to both paths.

---

## Path B: cluster with kube-vip

In this path there is no `keepalived` at all: the control plane virtual IP is served by a `kube-vip` static pod on each control plane node. Since the virtual IP does not exist yet when the seed node is initialized, you assign it by hand for the duration of `kubeadm init`, then hand it over to `kube-vip`.

  * [Assign the VIP to the seed node](#assign-the-vip-to-the-seed-node)
  * [Initialize the seed node](#initialize-the-seed-node-1)
  * [Release the temporary VIP](#release-the-temporary-vip)
  * [Deploy kube-vip on the seed node](#deploy-kube-vip-on-the-seed-node)
  * [Join the other nodes](#join-the-other-nodes-1)

then continue with the [common steps](#check-the-etcd-datastore).


> This path covers the control plane virtual IP only. If you also need a virtual IP for the workloads, either install the [kube-vip cloud provider](https://kube-vip.io/docs/usage/cloud-provider/) to get `Service` resources of type `LoadBalancer`, or set up `keepalived` on the worker nodes as described in [Path A](#setup-keepalived). 

> [!WARNING]
> Before continuing, read these [cautions](https://kube-vip.io/docs/modes/arp/?query=cautions#cautions) from KubeAPI docs regarding `kubelet` and `calico` internal IPs.

### Assign the VIP to the seed node
Attach the control plane virtual IP to the main interface of the seed node. This is temporary: it only serves to let `kubeadm init` bring up an API server that already answers on the cluster endpoint.

```bash
ssh ${USER}@${SEED} -t "sudo ip addr add ${MASTER_VIP}/24 dev ${MASTER_IF}"
ssh ${USER}@${SEED} -t "ip -brief addr show dev ${MASTER_IF}"
```

> Adjust the `/24` prefix to the netmask of your network. Do not assign the virtual IP to more than one machine.

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
  imageTag: ${COREDNS_VERSION} # Please make sure that this version is compliant with your cluster setup (see setup.env file in the repo)
controlPlaneEndpoint: "${MASTER_VIP}:${MASTER_PORT}"
kubernetesVersion: "${CLUSTER_VERSION}"
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

and check the single node cluster is up and reachable through the virtual IP:

```bash
export KUBECONFIG=$HOME/.kube/${CLUSTER_NAME}.kubeconfig
kubectl cluster-info
kubectl get nodes
```

### Release the temporary VIP
Now that the API server is running, remove the virtual IP from the seed node interface so that `kube-vip` can claim it:

```bash
ssh ${USER}@${SEED} -t "sudo ip addr del ${MASTER_VIP}/24 dev ${MASTER_IF}"
ssh ${USER}@${SEED} -t "ip -brief addr show dev ${MASTER_IF}"
```

> Between this step and the next one the cluster endpoint is unreachable, since nothing is answering on the virtual IP. This is expected.

### Deploy kube-vip on the seed node
Generate the `kube-vip` static pod manifest on the seed node with the `kube-vip` container image itself, and drop it into the `kubelet` static pod directory:

```bash
export VIP=${MASTER_VIP}
export INTERFACE=${MASTER_IF} # check the right interface for your environment
export KVVERSION=v1.2.3 #or for the latest KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")

ssh ${USER}@${SEED} <<EOF
  sudo ctr image pull ghcr.io/kube-vip/kube-vip:${KVVERSION}

  sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${KVVERSION} vip /kube-vip manifest pod \\
    --interface ${INTERFACE} \\
    --address ${VIP} \\
    --controlplane \\
    --arp \\
    --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
EOF
```

The `kubelet` picks up the manifest within seconds. Check that the virtual IP is back on the interface, this time owned by `kube-vip`:

```bash
ssh ${USER}@${SEED} -t "ip -brief addr show dev ${MASTER_IF}"
kubectl cluster-info
kubectl -n kube-system get pods -o wide
```

> If the `kube-vip` pod fails to authenticate against the API server, check which kubeconfig the generated manifest mounts. On recent Kubernetes releases the `admin.conf` credentials are no longer bound to `cluster-admin`, and the manifest has to point to `/etc/kubernetes/super-admin.conf` instead.

### Join the other nodes

Join the remaining control plane nodes:



```bash
MASTERS=(${MASTER1} ${MASTER2})
for i in "${!MASTERS[@]}"; do
  MASTER=${MASTERS[$i]}
  ssh ${USER}@${MASTER} 'sudo env JOIN_URL='${JOIN_URL}' env JOIN_TOKEN='${JOIN_TOKEN}' env JOIN_TOKEN_CERT_KEY='${JOIN_TOKEN_CERT_KEY}' env JOIN_TOKEN_CACERT_HASH='sha256:${JOIN_TOKEN_CACERT_HASH}' env JOIN_ASCP=true bash -s' -- < yaki join;
done
```

Then make the virtual IP highly available by shipping the same static pod manifest to the control plane nodes that just joined. Fetch it from the seed node:

```bash
scp ${USER}@${SEED}:/etc/kubernetes/manifests/kube-vip.yaml kube-vip.yaml
```

> The file is owned by `root` on the seed node. If the `scp` above is refused, copy it to the home directory first with `ssh ${USER}@${SEED} -t 'sudo cp /etc/kubernetes/manifests/kube-vip.yaml . && sudo chown $(id -u):$(id -g) kube-vip.yaml'` and fetch it from there.

and distribute it:

```bash
MASTERS=(${MASTER1} ${MASTER2})
for i in "${!MASTERS[@]}"; do
  MASTER=${MASTERS[$i]}
  ssh ${USER}@${MASTER} -t 'sudo mkdir -p /etc/kubernetes/manifests'
  scp kube-vip.yaml ${USER}@${MASTER}:kube-vip.yaml
  ssh ${USER}@${MASTER} -t 'sudo chown root:root kube-vip.yaml'
  ssh ${USER}@${MASTER} -t 'sudo mv kube-vip.yaml /etc/kubernetes/manifests/kube-vip.yaml'
done
```

Every control plane node now runs a `kube-vip` instance, and the leader election decides which one holds the virtual IP:

```bash
kubectl -n kube-system get pods -o wide
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

The cluster is now formed. Continue with the steps below, which are common to both paths.

---

## Check the etcd datastore
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

If you followed [Path A](#path-a-cluster-with-keepalived), `yaki reset` does not touch `keepalived`. To also drop the virtual IPs, remove the service from the hosts:

```bash
for i in "${!HOSTS[@]}"; do
  HOST=${HOSTS[$i]}
  ssh ${USER}@${HOST} -t 'sudo systemctl disable --now keepalived'
  ssh ${USER}@${HOST} -t 'sudo apt purge -y keepalived'
done
```

If you followed [Path B](#path-b-cluster-with-kube-vip), `yaki reset` wipes `/etc/kubernetes`, so the `kube-vip` static pod manifest goes away with it and the virtual IP is released.

Either way, confirm no leftover address is pinned on the control plane interfaces:

```bash
for i in "${!MASTERS[@]}"; do
  MASTER=${MASTERS[$i]}
  ssh ${USER}@${MASTER} -t "ip -brief addr show dev ${MASTER_IF}"
done
```

> If there is some pinned leftover address on some interface, remove it with `ssh ${USER}@$<master-target> -t "sudo ip addr del ${MASTER_VIP}/32 dev ${MASTER_IF}"` command. 


That's all folks!
