#!/bin/bash

# $1 is the command:
# Multipass: create, delete, purge
# DigitalOcean: do-create, do-delete

# Global settings
# MASTERS: $2 or set 2 as default
MASTERS=${2:-1}
# WORKERS: $3 or set 1 as default
WORKERS=${3:-1}
# LABOR: $4 or set cka02 as default
LABOR=${4:-"cka02"}
LABOR_MASTER="${LABOR}-master"
LABOR_WORKER="${LABOR}-worker"
# DOMAIN: $5 or set cka02.devopsakademia.com as default
DOMAIN=${5:-"cka02.devopsakademia.com"}

# Multipass settings
DIST="noble" # Ubuntu 24.04 or "jammy" for Ubuntu 22.04
MASTER_CPU=4
MASTER_RAM=6G
MASTER_DISK=20G
WORKER_CPU=1
WORKER_RAM=2G
WORKER_DISK=20G
NETWORK="bridged"

# DigitalOcean settings
PROJECT="CKA02"
DROPLET_SIZE_MASTER="s-2vcpu-2gb"
DROPLET_SIZE_WORKER="s-2vcpu-2gb"
DROPLET_IMAGE="ubuntu-24-04-x64"
DROPLET_REGION="fra1"

# Check if the user has an ssh key
if [ -f ~/.ssh/id_rsa.pub ]; then
    export SSH_PUBKEY=$(cat ~/.ssh/id_rsa.pub)
    sed -e 's|^      - ssh-rsa .*|      - '"${SSH_PUBKEY}"'|' user-data.yaml > user-data-ssh.yaml
fi

# Set CLOUD_INIT to user-data-ssh.yaml if exists, otherwise to user-data.yaml
if [ -f user-data-ssh.yaml ]; then
    CLOUD_INIT=user-data-ssh.yaml
else
    CLOUD_INIT=user-data.yaml
fi

##
## Multipass
##
# Check if multipass is installed
multipass_check() {
    if ! command -v multipass &> /dev/null; then
        echo "multipass could not be found"
        exit 1
    fi
}

# Multipass create node: name cpu ram disk
multipass_create() {
    FQDN="${1}'.'${DOMAIN}"
    sed -e 's|FQDN|'${FQDN}'|' ${CLOUD_INIT} \
        | multipass launch ${DIST} --name ${1} --cpus ${2} --memory ${3} --disk ${4} --network ${NETWORK} --cloud-init -
    # Check for errors and exit if any
    if [ $? -ne 0 ]; then
        echo "Error creating ${1}"
        exit 1
    fi
}

# Create master nodes: add multipass_create_master function with the argument of the number of nodes
multipass_create_master() {
    for i in $(seq -f "%02g" 1 $1); do
        multipass_create ${LABOR_MASTER}-${i} ${MASTER_CPU} ${MASTER_RAM} ${MASTER_DISK}
    done
}

# Create worker nodes: add multipass_create_worker function with the argument of the number of nodes
multipass_create_worker() {
    for i in $(seq -f "%02g" 1 $1); do
        multipass_create ${LABOR_WORKER}-${i} ${WORKER_CPU} ${WORKER_RAM} ${WORKER_DISK}
    done
}

# Delete all nodes created by this script
multipass_delete_nodes() {
    # Delete workers
    for i in $(seq -f "%02g" 1 ${WORKERS}); do
        multipass delete ${LABOR_WORKER}-${i}
    done
    # Delete masters
    for i in $(seq -f "%02g" 1 ${MASTERS}); do
        multipass delete ${LABOR_MASTER}-${i}
    done
}

##
## DigitalOcean
##
# Check if we have a working doctl
doctl_check() {
    # Check if doctl is installed
    if ! command -v doctl &> /dev/null; then
        echo "doctl could not be found"
        exit 1
    fi
    # Check if we are authenticated
    if ! doctl auth list | grep -q "current"; then
        echo "doctl is not authenticated"
        exit 1
    fi
    # Get the project ID if not set
    if [ -z ${PROJECT_ID} ]; then
        export PROJECT_ID=$(doctl projects list --no-header --format ID,Name | grep ${PROJECT} | cut -d' ' -f1)
    fi
    if [ -z ${PROJECT_ID} ]; then
        echo "Project ${PROJECT} not found"
        exit 1
    fi
}

# Create DigitalOcean Droplet: name size
do_create() {
        FQDN="${1}'.'${DOMAIN}"
        USER_DATA=$(mktemp user-data-do.yaml.XXXXXX)
        sed -e 's|FQDN|'${FQDN}'|' ${CLOUD_INIT} > ${USER_DATA}
        doctl compute droplet create ${1} \
            --wait \
            --project-id ${PROJECT_ID} \
            --image ${DROPLET_IMAGE} \
            --region ${DROPLET_REGION} \
            --size ${2} \
            --ssh-keys $(doctl compute ssh-key list --no-header --format ID) \
            --user-data-file ${USER_DATA}
        rm -f ${USER_DATA}
        # Check for errors and exit if any
        if [ $? -ne 0 ]; then
            echo "Error creating ${1}"
            exit 1
        fi
}

# Create master nodes: add do_create_master function with the argument of the number of nodes
do_create_master() {
    for i in $(seq -f "%02g" 1 $1); do
        do_create ${LABOR_MASTER}-${i} ${DROPLET_SIZE_MASTER}
    done
}

# Create worker nodes: add do_create_worker function with the argument of the number of nodes
do_create_worker() {
    for i in $(seq -f "%02g" 1 $1); do
        # use two digits number for $i
        do_create ${LABOR_WORKER}-${i} ${DROPLET_SIZE_WORKER}
    done
}

# Delete all nodes created by this script
do_delete_nodes() {
    # Delete workers
    for i in $(seq -f "%02g" 1 ${WORKERS}); do
        doctl compute droplet delete ${LABOR_WORKER}-${i} --force
    done
    # Delete masters
    for i in $(seq -f "%02g" 1 ${MASTERS}); do
        doctl compute droplet delete ${LABOR_MASTER}-${i} --force
    done
}

# Check for command: create, delete, purge, do-create, do-delete
case $1 in
    create)
        multipass_check
        echo "Creating Multipass nodes..."
        multipass_create_master ${MASTERS}
        multipass_create_worker ${WORKERS}
        multipass list
        exit 0
        ;;
    delete)
        multipass_check
        echo "Deleting Multipass nodes..."
        multipass_delete_nodes
        multipass list
        echo "Use multipass purge to permanently delete the nodes"
        exit 0
        ;;
    purge)
        multipass_check
        echo "Deleting and purging Multipass nodes..."
        multipass_delete_nodes
        multipass purge
        exit 0
        ;;
    do-create)
        doctl_check
        echo "Creating DigitalOcean Droplets..."
        do_create_master ${MASTERS}
        do_create_worker ${WORKERS}
        sleep 1s
        doctl compute droplet list
        exit 0
        ;;
    do-delete)
        doctl_check
        echo "Deleting DigitalOcean Droplets..."
        do_delete_nodes
        doctl compute droplet list
        exit 0
        ;;
    *)
        echo "Usage: $0 create|delete|purge|do-create|do-delete [MASTERS:${MASTERS}] [WORKERS:${WORKERS}] [LABOR:${LABOR}] [DOMAIN:${DOMAIN}]"
        exit 1
        ;;
esac
