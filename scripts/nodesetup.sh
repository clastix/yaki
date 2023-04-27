#!/bin/bash

set -e

# increases output verbosity during script execution
if [ "${DEBUG}" = 1 ]; then
    set -x
    KUBEADM_VERBOSE="-v=8"
else
    KUBEADM_VERBOSE="-v=4"
fi

BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
SERVICE_DIR="/etc/systemd/system"

COMMAND=$1

helper() {
    echo "Usage: "
    echo "  INSTALL_METHOD=... KUBERNETES_VERSION=... CRICTL_VERSION=... ./nodesetup.sh <command>"
    echo ""
    echo "Commands:"
    echo "  prepare: Prepare the node for kubernetes installation (default command)"
    echo "  init: Deploy the first control-plane node of the kubernetes cluster"
    echo "  join: Join the node to the cluster"
    echo "  reset: Reset the node"
    echo "  help: Print this help"
    echo ""
    echo "Environment variables:"
    echo "  INSTALL_METHOD: The installation method to use: 'apt', 'tar' (TBD), 'rpm', or 'airgap' (TBD). Default is 'apt'"
    echo "  KUBERNETES_VERSION: Version of kubernetes to install. Default is '1.26.X'"
    echo "  CRICTL_VERSION: Version of crictl to install. Default is 'v1.26.0'"
    echo "  KUBEADM_CONFIG: Path to the kubeadm config file to use. Default is not set."
    echo "  KUBEADM_ADVERTISE_ADDRESS: Address to advertise for the node. Default is '0.0.0.0'"
    echo "  JOIN_TOKEN: Token to join the control-plane, node will not join if not passed. Default is 'abcdef.1234567890abcdef'"
    echo "  JOIN_TOKEN_CACERT_HASH: Token Certificate Authority hash to join the control-plane, node will not join if not passed. Default is not set."
    echo "  JOIN_URL: URL to join the control-plane, node will not join if not passed. Default is not set."
    echo "  DEBUG: Set to 1 for more verbosity during script execution. Default is 0."
    echo ""
}

# setup_arch set arch and suffix, fatal if architecture is not supported.
setup_arch() {
    case ${ARCH:=$(uname -m)} in
    amd64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    x86_64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    arm64)
        ARCH=arm64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    *)
        fatal "unsupported architecture ${ARCH}"
        ;;
    esac
}

# setup_env defines needed environment variables.
setup_env() {
    # must be root
    if [ ! "$(id -u)" -eq 0 ]; then
        fatal "You need to be root to perform this install"
    fi

    # use 'apt' install method if available by default
    if [ -z "${INSTALL_METHOD}" ] && command -v apt >/dev/null 2>&1; then
        INSTALL_METHOD="apt"
    fi

    # use a tested version of kubernetes if not passed
    # N.B. don't insert the initial 'v' in the version string (apt/tar compatibility)
    if [ -z "${KUBERNETES_VERSION}" ]; then
        warn "The kubernetes version has not been passed, a tested version will be used"
        KUBERNETES_VERSION="1.26.4"
    fi

    # use a tested version of crictl if not passed
    if [ -z "${CRICTL_VERSION}" ]; then
        warn "The crictl version has not been passed, a tested version will be used"
        CRICTL_VERSION="v1.26.0"
    fi

    # use a predefined kubeadm TOKEN if not passed
    if [ -z "${JOIN_TOKEN}" ]; then
        warn "The join token has not been passed, a predefined token will be used"
        JOIN_TOKEN="abcdef.1234567890abcdef"
    fi

    # use a predefined kubeadm KUBEADM_ADVERTISE_ADDRESS if not passed
    if [ -z "${KUBEADM_ADVERTISE_ADDRESS}" ]; then
        warn "The advertise address has not been passed, a predefined address will be used"
        KUBEADM_ADVERTISE_ADDRESS="0.0.0.0"
    fi
}

# info logs the given argument at info log level.
info() {
    echo "[INFO] " "$@"
}

# warn logs the given argument at warn log level.
warn() {
    echo "[WARN] " "$@" >&2
}

# fatal logs the given argument at fatal log level.
fatal() {
    echo "[ERROR] " "$@" >&2
    exit 1
}

setup_prerequisites() {
    info "Set node prerequisites: "
    info "  - disable swap"

    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab

    info "  - enable required kernel modules"
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    info "  - forwarding IPv4 and letting iptables see bridged traffic"
    # sysctl params required by setup, params persist across reboots
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # Apply sysctl params without reboot
    sysctl --system
}

install_containerd() {
    info "installing containerd"
    wget https://github.com/containerd/containerd/releases/download/v1.6.15/containerd-1.6.15-linux-amd64.tar.gz && \
    	tar Cxzvf /usr/local containerd-1.6.15-linux-amd64.tar.gz

    mkdir -p /usr/local/lib/systemd/system/ && \
    	wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service && \
    	mv containerd.service /usr/local/lib/systemd/system/
        rm -f containerd-1.6.15-linux-amd64.tar.gz

    wget https://github.com/opencontainers/runc/releases/download/v1.1.4/runc.amd64 && \
        chmod 755 runc.amd64 && \
        mv runc.amd64 "${SBIN_DIR}"/runc

    mkdir -p /opt/cni/bin && \
    	wget https://github.com/containernetworking/plugins/releases/download/v1.2.0/cni-plugins-linux-amd64-v1.2.0.tgz && \
    	tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.2.0.tgz
        rm -f cni-plugins-linux-amd64-v1.2.0.tgz

    mkdir -p /etc/containerd
    containerd config default | sed -e "s#SystemdCgroup = false#SystemdCgroup = true#g" | tee /etc/containerd/config.toml

    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl restart containerd

}

install_crictl() {
    info "installing crictl"
    curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/"${CRICTL_VERSION}"/crictl-"${CRICTL_VERSION}"-linux-"${ARCH}".tar.gz" |\
    tar -C "${BIN_DIR}" -xz

    # configure crictl to work with containerd endpoints
    cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF

}

apt_install_containerd() {
    info "installing containerd"
    apt update
    apt install -y containerd
    mkdir -p /etc/containerd
    containerd config default | sed -e "s#SystemdCgroup = false#SystemdCgroup = true#g" | tee /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd
    apt-mark hold containerd
}

apt_install_kube() {
    info "Update the apt package index and install packages needed to use the Kubernetes apt repository"
    apt install -y apt-transport-https ca-certificates socat conntrack

    info "Download the Google Cloud public signing key"
    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

    info "Add the Kubernetes apt repository"
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list

    info "Download and install kubernetes components"
    local VERSION
    if [ -n "${KUBERNETES_VERSION}" ]; then
        VERSION="=${KUBERNETES_VERSION}-00"
    fi

    apt update
    apt install -y kubelet"${VERSION}" kubeadm"${VERSION}" kubectl"${VERSION}" --allow-downgrades --allow-change-held-packages
    apt-mark hold kubelet kubeadm kubectl
}

install_kube() {
    info "Update the apt package index and install packages needed to use the Kubernetes apt repository"
    apt install -y apt-transport-https ca-certificates socat conntrack
    
    wget https://storage.googleapis.com/kubernetes-release/release/v"${KUBERNETES_VERSION}"/bin/linux/"${ARCH}"/{kubeadm,kubelet,kubectl} && \
        chmod +x {kubeadm,kubelet,kubectl} && \
        mv {kubeadm,kubelet,kubectl} "${BIN_DIR}"

    RELEASE_VERSION="v0.4.0"
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/"${RELEASE_VERSION}"/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" |\
        sed "s:/usr/bin:${BIN_DIR}:g" |\
        tee ${SERVICE_DIR}/kubelet.service

    mkdir -p ${SERVICE_DIR}/kubelet.service.d
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/"${RELEASE_VERSION}"/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" |\
        sed "s:/usr/bin:${BIN_DIR}:g" |\
        tee ${SERVICE_DIR}/kubelet.service.d/10-kubeadm.conf
    
    systemctl enable --now kubelet
}

init_cluster() {
    if [ -z "${JOIN_URL}" ]; then
        fatal "The join url has not been passed, ABORTING"
        return
    fi

    info "Initializing the control-plane"
    local KUBEADM_ARGS="--token ${JOIN_TOKEN} --control-plane-endpoint ${JOIN_URL} --apiserver-advertise-address ${KUBEADM_ADVERTISE_ADDRESS} --upload-certs"
    if [ -f "${KUBEADM_CONFIG}" ]; then
        KUBEADM_ARGS="--config ${KUBEADM_CONFIG}"
    fi
    kubeadm init ${KUBEADM_ARGS} "${KUBEADM_VERBOSE}"
}

join_node() {
    if [ -z "${JOIN_URL}" ]; then
        fatal "The join url has not passed, the machine will not be part of the cluster"
        return
    fi

    # TO DO
    # generate random certificate-key instead of skipping the CA verification
    info "Joining the node to the cluster"
    local KUBEADM_ARGS="${JOIN_URL} --token ${JOIN_TOKEN}"
    if [ -n "${JOIN_TOKEN_CACERT_HASH}" ]; then
        KUBEADM_ARGS="${KUBEADM_ARGS} --discovery-token-ca-cert-hash ${JOIN_TOKEN_CACERT_HASH}"
    else
        warn "Skipping CA verification"
        KUBEADM_ARGS="${KUBEADM_ARGS} --discovery-token-unsafe-skip-ca-verification"
    fi

    if [ "${IS_CONTROLPLANE}" ]; then
        KUBEADM_ARGS="${KUBEADM_ARGS} --control-plane"
    elif [ -f "${KUBEADM_CONFIG}" ]; then
        KUBEADM_ARGS="--config ${KUBEADM_CONFIG}"
    fi

    kubeadm join ${KUBEADM_ARGS} "${KUBEADM_VERBOSE}"
}

verify_join_url() {
    local join_url=${JOIN_URL#http://}  # strip "http://" prefix
    local join_url=${JOIN_URL#https://}  # strip "https://" prefix
    join_url=${join_url%%:*}  # strip everything after the first colon (port number)

    # resolve JOIN_URL to an IP address
    local resolved_ip=$(getent ahosts ${join_url} | awk 'NR==1 {print $1}')

    if [[ -z ${resolved_ip} ]]; then
        warn "Unable to resolve JOIN_URL (${join_url}) to an IP address or JOIN_URL is not a valid FQDN"
        return 1  # error
    fi

    local ip_addresses=$(hostname -I)

    # check if resolved IP address is in the list of IP addresses
    for ip_address in ${ip_addresses}; do
        if [[ ${resolved_ip} == ${ip_address} ]]; then
            return 0  # success
        fi
    done

    # resolved IP address not found in IP address list
    warn "The resolved IP address (${resolved_ip}) for JOIN_URL (${JOIN_URL}) is not contained inside the operating system network interfaces"
    return 1  # error
}

# install container runtime and kubernetes components
install() {
    case ${INSTALL_METHOD} in
    apt)
        install_crictl
        #apt_install_containerd
        install_containerd
        apt_install_kube "${KUBERNETES_VERSION}"
        ;;
    rpm)
        fatal "currently unsupported install method ${INSTALL_METHOD}"
        ;;
    tar)
        install_crictl
        install_containerd
        install_kube "${KUBERNETES_VERSION}"
        ;;
    airgap)
        fatal "currently unsupported install method ${INSTALL_METHOD}"
        ;;
    *)
        fatal "unknown install method ${INSTALL_METHOD}"
        ;;
    esac
}

remove_kube() {
    info "removing kubernetes components"
    systemctl stop kubelet
    kubeadm reset -f
    apt remove --purge kubelet kubeadm kubectl -y --allow-change-held-packages
    apt autoremove -y

    rm -rf ${BIN_DIR}/{kubeadm,kubelet,kubectl} \
        /etc/kubernetes \
        /var/run/kubernetes \
        /var/lib/kubelet \
        /var/lib/etcd \
        ${SERVICE_DIR}/kubelet.service \
        ${SERVICE_DIR}/kubelet.service.d
}

remove_containerd() {
    info "removing containerd"
    systemctl stop containerd
    apt remove --purge containerd -y
    apt autoremove -y

    rm -rf ${BIN_DIR}/containerd* \
        ${BIN_DIR}/ctr \
        /etc/containerd/ \
        /usr/local/lib/systemd/system/containerd.service

    # remove containerd side tools
    rm -rf ${SBIN_DIR}/runc \
        ${BIN_DIR}/crictl \
        /etc/crictl.yaml
}

remove_binaries() {
    info "removing side configuration files and binaries"
    rm -rf /etc/cni/net.d \
        /opt/cni/bin \
        /var/lib/cni \
        /var/run/calico \
        /var/log/containers \
        /var/log/pods
}

clean_iptables() {
    info "cleaning up iptables"
    iptables -F && \
        iptables -t nat -F && \
        iptables -t mangle -F && \
        iptables -X
}

clean_ipvs() {
    info "cleaning up ipvs"
    ipvsadm -C
}

# commands

do_prepare() {
    info "Prepare the machine for kubernetes"
    setup_prerequisites
    install
}

do_kube_init() {
    # verify if the resolved JOIN_URL is contained inside the VM network interfaces
    if verify_join_url; then
        info "Creating k8s cluster"
        init_cluster
    else
        info "Joining node as another control-plane for HA"
        declare -g IS_CONTROLPLANE=true
        join_node
    fi
}

do_kube_join() {
    info "Joining node as a worker"
    join_node
}

do_reset() {
    # TODO
    # remove pending pods

    info "cleaning up"
    remove_kube
    remove_containerd
    remove_binaries

    clean_iptables
    clean_ipvs

    systemctl restart systemd-networkd
    systemctl daemon-reload
}

# main script

setup_arch
setup_env

case ${COMMAND} in
"" | prepare)
    do_prepare && \
    info "setup completed successfully"
    ;;
init)
    do_kube_init && \
    info "init completed successfully"
    ;;
join)
    do_kube_join && \
    info "join completed successfully"
    ;;
reset)
    do_reset && \
    info "reset completed successfully"
    ;;
help)
    helper
    ;;
*)
    helper && \
    fatal "unknown command ${COMMAND}"
    ;;
esac
