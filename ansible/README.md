# Getting Started
This guide will help you install Ansible and run the playbook for setting up a Kubernetes cluster.

## Prerequisites
A local machine with a supported operating system (e.g., Ubuntu, CentOS).
SSH access to the target machines.
Python installed on the local machine.

## Install Ansible
On the local machine, run:

```
sudo apt install python3 python3-pip -y
pip3 install ansible
ansible --version
```

## Configure Inventory

Edit the `inventory/hosts` file for matching your environment.

## Configure Group Variables

Edit the `group_vars/all.yml` file for matching your preferences.

## Running the Playbook

To run the playbook:

* Setup Cluster: `ansible-playbook playbooks/setup.yml`


