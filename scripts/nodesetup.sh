#!/bin/bash

set -e

DOWNLOAD_DIR="/usr/local/bin"

if [ "${DEBUG}" = 1 ]; then
    set -x
    KUBEADM_VERBOSE="-v=8"
else
    KUBEADM_VERBOSE="-v=4"
fi

echo "Hello"
