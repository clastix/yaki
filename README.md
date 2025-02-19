# Yaki

**Yaki - Another Kubernetes Installer** leads the installation of a barebone **Kubernetes** cluster in a simplified and automated way and it is entirely independent of the infrastructure you’re running on.

It leverages on [kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/), one of the official installation tools from Kubernetes community.

> New to Kubernetes? The official Kubernetes docs already have some great tutorials outlining the basics [here](https://kubernetes.io/docs/tutorials/kubernetes-basics/).

## Getting Started

This readme will help you quickly launch a cluster with default options.

### Requirements

Make sure your environment fulfills following requirements:

* A set of compatible Linux machines with `systemd`. We widely useing `yaki` on **Ubuntu 20.04** and **Ubuntu 22.04**.
* Full network connectivity between all machines in the cluster (public or private network is fine).
* Unique hostname, MAC address, and IP address for every machine.
* Swap configuration. The default behavior of a `kubeadm` install was to fail to start if swap memory was detected.
* Must be run as the root user or through `sudo`.

### Prerequisites

The script expects some tools to be installed on your machines. It will fail if they are not found: `conntrack`, `socat`, `wget`.

> Most of them should be already available in a bare Ubuntu installation.

### Initialize Cluster

Choose a "seed" machine hosting the control plane of the Kubernetes cluster, login to the machine and run:

```bash
curl -sfL https://goyaki.clastix.io | sudo bash -s init
```

the script will setup the machine, install the container runtime `containerd`, among other required tools, install the `kubelet`, `kubeadm`, `kubectl` binaries and setup the control plane.

Once the initialization completes, take note of the output:

```bash
JOIN_URL=<join-url>
JOIN_TOKEN=<token>
JOIN_TOKEN_CERT_KEY=<certificate-key>
JOIN_TOKEN_CACERT_HASH=sha256:<discovery-token-ca-cert-hash>
``` 

To start using your cluster, you need to run the following as a regular user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Alternatively, if you are the root user, you can run:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

> If you are adding additional control plane nodes, you must have an odd number in total. An odd number is needed to maintain quorum. See [Advanced Usage](guides/advanced.md) for more details.

### Join Workers

To join other machines as worker nodes, you have to run `yaki` on each machine passing the `join` command along with some variables. Login to the machine you want to turn in a worker node and run:

```bash
curl -sfL https://goyaki.clastix.io | sudo JOIN_URL=<join-url> JOIN_TOKEN=<token> JOIN_TOKEN_CACERT_HASH=sha256:<hash> bash -s join
```

the script will setup the machine, install the container runtime `containerd`, among other required tools, install the `kubelet`, `kubeadm`, `kubectl` binaries and join the machine to the control plane node.


### Working with the Cluster

Once joined all the desired worker nodes, back to the machine hosting the Control Plane and check the cluster has formed:

```bash
kubectl get nodes
```

Cluster nodes are still in a `NotReady` state because of the missing CNI add-on.

Please refer to the [Installing Addons](https://kubernetes.io/docs/concepts/cluster-administration/addons/#networking-and-network-policy) page for a non-exhaustive list of networking addons supported by Kubernetes. You can install a Pod network add-on with the following command:

```bash
kubectl apply -f <add-on.yaml>
```

## Documentation

The `yaki` tool is self-documented:

```bash
$ curl -sfL https://goyaki.clastix.io | sudo bash -s help
Usage:

  ENV=... yaki.bash <init|join|reset|help>
    or
  curl -sfL https://goyaki.clastix.io | ENV=... bash -s <init|join|reset|help>

Commands:

  init: Deploy the first control-plane node of the Kubernetes cluster
    - This command initializes the Kubernetes control-plane on the first node.
    - Requires: JOIN_URL (optional), KUBEADM_CONFIG (optional), ADVERTISE_ADDRESS(optional), BIND_PORT (optional), KUBERNETES_VERSION (optional)
    - Example: KUBERNETES_VERSION=v1.30.5 yaki init
    - Example: JOIN_URL=<control-plane-endpoint>:<port> KUBERNETES_VERSION=v1.30.5 yaki init
    - Example: KUBEADM_CONFIG=kubeadm-config.yaml KUBERNETES_VERSION=v1.30.5 yaki init

  join: Join a control plane node to the cluster
    - This command joins the node as control plane to an existing Kubernetes cluster.
    - It also installs all necessary prerequisites, container runtime, CNI plugins, and Kubernetes binaries.
    - Requires: JOIN_URL, JOIN_TOKEN, JOIN_TOKEN_CACERT_HASH, JOIN_ASCP, KUBERNETES_VERSION (optional)
    - Example: JOIN_URL=<control-plane-endpoint>:<port> JOIN_TOKEN=<token> JOIN_TOKEN_CERT_KEY=<key> JOIN_TOKEN_CACERT_HASH=sha256:<hash> JOIN_ASCP=true KUBERNETES_VERSION=v1.30.5 yaki join

  join: Join a node to the cluster
    - This command joins the node to an existing Kubernetes cluster.
    - Requires: JOIN_URL, JOIN_TOKEN, JOIN_TOKEN_CACERT_HASH, KUBERNETES_VERSION (optional)
    - Example: JOIN_URL=<control-plane-endpoint>:<port> JOIN_TOKEN=<token> JOIN_TOKEN_CACERT_HASH=sha256:<hash> KUBERNETES_VERSION=v1.30.5 yaki join

  reset: Reset the node
    - This command removes all Kubernetes components and configurations from the node.
    - Example: yaki reset

  help: Print this help
    - Displays this help message.
    - Example: yaki help

Environment variables:

  +-------------------------+-------------------------------------------------------------+------------+
  | Variable                | Description                                                 | Default    |
  +-------------------------+-------------------------------------------------------------+------------+
  | KUBERNETES_VERSION      | Version of kubernetes to install.                           | v1.30.5    |
  | CONTAINERD_VERSION      | Version of container runtime containerd.                    | see matrix |
  | RUNC_VERSION            | Version of runc to install.                                 | see matrix |
  | CNI_VERSION             | Version of CNI plugins to install.                          | see matrix |
  | CRICTL_VERSION          | Version of crictl to install.                               | see matrix |
  | KUBEADM_CONFIG          | Path to the kubeadm config file to use.                     | Not set    |
  | ADVERTISE_ADDRESS       | Address to advertise for the api-server.                    | 0.0.0.0    |
  | BIND_PORT               | Port to use for the api-server.                             | 6443       |
  | JOIN_TOKEN              | Token to join the control-plane.                            | Not set    |
  | JOIN_TOKEN_CACERT_HASH  | Token Certificate Authority hash to join the control-plane. | Not set    |
  | JOIN_TOKEN_CERT_KEY     | Token Certificate Key to join the control-plane.            | Not set    |
  | JOIN_URL                | URL to join the control-plane.                              | Not set    |
  | JOIN_ASCP               | Switch to join either as control plane or worker.           | false      |
  | DEBUG                   | Set to 1 for more verbosity during script execution.        | false      |
  +-------------------------+-------------------------------------------------------------+------------+
```

## Advanced Usage

A guide with more advanced usage of `yaki` can be found [here](guides/advanced.md).

## Contributions

This is an open-source tool. If you find errors, typos, or just want to improve `yaki`, feel free to open a pull request. Contributions are always welcome!
