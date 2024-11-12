#!/bin/bash
#
# Copyright 2023 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

NUM_GPUS=${NUM_GPUS:-1}
VM_NAME=${VM_NAME:-rhel-ai}
RAM=${RAM:-40960}
CPUS=${CPUS:-12}
DISK=${DISK:-50}

IMAGE_NAME=rhel-ai
WAIT_FOR_IMAGE=false

if ! openstack image show ${IMAGE_NAME}; then
    source ~/cloudrc
    glance --force image-create-via-import \
        --disk-format qcow2 \
        --container-format bare \
        --name $IMAGE_NAME \
        --visibility public \
        --import-method web-download \
        --uri http://192.168.130.1/rhel-ai-disk.qcow2
    WAIT_FOR_IMAGE=true
fi

# Create flavor
openstack flavor show nvidia || \
    openstack flavor create --ram ${RAM} --vcpus ${CPUS} --disk ${DISK} nvidia \
      --property "pci_passthrough:alias"="nvidia:${NUM_GPUS}" \
      --property "hw:pci_numa_affinity_policy=preferred" \
      --property "hw:hide_hypervisor_id"=true

# Create networks
openstack network show private || openstack network create private --share
openstack subnet show priv_sub || openstack subnet create priv_sub --subnet-range 192.168.0.0/24 --network private
openstack network show public || openstack network create public --external --provider-network-type flat --provider-physical-network datacentre
openstack subnet show public_subnet || \
    openstack subnet create public_subnet --subnet-range 192.168.122.0/24 --allocation-pool start=192.168.122.171,end=192.168.122.250 --gateway 192.168.122.1 --dhcp --network public
openstack router show priv_router || {
    openstack router create priv_router
    openstack router add subnet priv_router priv_sub
    openstack router set priv_router --external-gateway public
}

# Create security group and icmp/ssh rules
openstack security group show basic || {
    openstack security group create basic
    openstack security group rule create basic --protocol icmp --ingress --icmp-type -1
    openstack security group rule create basic --protocol tcp --ingress --dst-port 22

    openstack security group rule create basic --protocol tcp --remote-ip 0.0.0.0/0
}

# List External compute resources
openstack compute service list
openstack network agent list

# Create an instance
openstack server show ${VM_NAME} || {
    openstack keypair show ${VM_NAME} || {
        openstack keypair create ${VM_NAME} > ${VM_NAME}.pem
        # openstack keypair create --public-key ~/.ssh/id_rsa.pub ${VM_NAME}
        chmod 600 ${VM_NAME}.pem
    }

    if [[ "${WAIT_FOR_IMAGE}" == "true" ]]; then
        echo "Waiting for the image ${IMAGE_NAME} to become available"
        while [[ "$(openstack image show -c status -f value ${IMAGE_NAME})" == "importing" ]]; do
            sleep 1
        done
        if [[ "$(openstack image show -c status -f value ${IMAGE_NAME})" != "active" ]]; then
            print "Error importing image ${IMAGE_NAME}"
            exit 1
        fi
    fi
    openstack server create --flavor nvidia --image ${IMAGE_NAME} --key-name ${VM_NAME} --nic net-id=private ${VM_NAME} --security-group basic --wait
    if [[ "$(openstack server show -c status -f value ${VM_NAME})" == "ERROR" ]]; then
        echo "Failed to create instance ${VM_NAME}"
        exit 2
    fi
    fip=$(openstack floating ip create public -f value -c floating_ip_address)
    openstack server add floating ip ${VM_NAME} ${fip}
}
openstack server list --long

echo "Pinging $fip for 120 seconds until it responds"
timeout 120 bash -c "while true; do if ping -c1 -i1 $fip &>/dev/null; then echo 'Machine is up and running up'; break; fi; done"

echo "Changing the default DNS nameserver in the instance to 1.1.1.1"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./${VM_NAME}.pem cloud-user@${fip} 'echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf'

if [[ -e ~/pull-secret ]]; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./${VM_NAME}.pem cloud-user@${fip} 'mkdir ~/.docker'
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./${VM_NAME}.pem ~/pull-secret cloud-user@${fip}:~/.docker/config.json
fi

echo "Access VM with: oc rsh openstackclient ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./${VM_NAME}.pem cloud-user@${fip}"
