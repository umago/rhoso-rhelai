#!/bin/bash
#
# Copyright 2022 Red Hat Inc.
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
# Useful Env Vars
# DISK_FILEPATH ==> Can be used to create the disk in a different pool
set -ex
export LIBVIRT_DEFAULT_URI=qemu:///system
CRC_POOL=${CRC_POOL:-"$HOME/.crc/machines/crc"}
OUTPUT_DIR=${OUTPUT_DIR:-"../out"}
MY_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$MY_TMP_DIR"' EXIT

EDPM_SERVER_ROLE=${EDPM_SERVER_ROLE:-"compute"}
FIRSTBOOT_EXTRA=${FIRSTBOOT_EXTRA:-"/tmp/edpm-firstboot-extra"}

EDPM_COMPUTE_SUFFIX=${1:-"0"}
EDPM_COMPUTE_NAME=${EDPM_COMPUTE_NAME:-"edpm-${EDPM_SERVER_ROLE}-${EDPM_COMPUTE_SUFFIX}"}
EDPM_COMPUTE_VCPUS=${EDPM_COMPUTE_VCPUS:-8}
EDPM_COMPUTE_RAM=${EDPM_COMPUTE_RAM:-20}
EDPM_COMPUTE_DISK_SIZE=${EDPM_COMPUTE_DISK_SIZE:-70}
EDPM_COMPUTE_NETWORK=${EDPM_COMPUTE_NETWORK:-default}
EDPM_COMPUTE_NETWORK_TYPE=${EDPM_COMPUTE_NETWORK_TYPE:-network}
# Use a json string to add additonal networks:
# '[{"type": "network", "name": "crc-bmaas"}, {"type": "network", "name": "other-net"}]'
EDPM_COMPUTE_ADDITIONAL_NETWORKS=${EDPM_COMPUTE_ADDITIONAL_NETWORKS:-'[]'}
EDPM_COMPUTE_NETWORK_IP=$(virsh net-dumpxml ${EDPM_COMPUTE_NETWORK} | xmllint --xpath 'string(/network/ip/@address)' -)
DATAPLANE_DNS_SERVER=${DATAPLANE_DNS_SERVER:-${EDPM_COMPUTE_NETWORK_IP}}
CENTOS_9_STREAM_URL=${CENTOS_9_STREAM_URL:-"https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"}
EDPM_IMAGE_URL=${EDPM_IMAGE_URL:-"${CENTOS_9_STREAM_URL}"}
BASE_DISK_FILENAME=${BASE_DISK_FILENAME:-"$(basename ${EDPM_IMAGE_URL})"}

DISK_FILENAME=${DISK_FILENAME:-"edpm-${EDPM_SERVER_ROLE}-${EDPM_COMPUTE_SUFFIX}.qcow2"}
DISK_FILEPATH=${DISK_FILEPATH:-"${CRC_POOL}/${DISK_FILENAME}"}

SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-"${OUTPUT_DIR}/ansibleee-ssh-key-id_rsa.pub"}
MAC_ADDRESS=${MAC_ADDRESS:-"$(echo -n 52:54:00; dd bs=1 count=3 if=/dev/random 2>/dev/null | hexdump -v -e '/1 "-%02X"' | tr '-' ':')"}
IP_ADRESS_SUFFIX=$((100+${EDPM_COMPUTE_SUFFIX}))

if [ ! -f ${SSH_PUBLIC_KEY} ]; then
    echo "${SSH_PUBLIC_KEY} is missing. Run gen-ansibleee-ssh-key.sh"
    exit 1
fi

if [ ! -d "${HOME}/.ssh" ]; then
    mkdir "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    restorecon -R "${HOME}/.ssh"
fi

# - We cannot pass multiple PCI devices (GPU + Audio) when we enable iommu
#   https://bugzilla.redhat.com/show_bug.cgi?id=2050175
#
# - According to https://wiki.qemu.org/Features/VT-d to fully enable vIOMMU
#   functionality `intremap=on` must be set, but currently interrupt remapping
#   does not support full kernel irqchip, only "split" and "off" are supported.
#   That's why we set `<ioapic driver='qemu'/>`, it sets `kernel_irqchip=split`
#   in QEMU. Setting it to `kvm` would be equivalent to `on`.

# Change the qemu part to use the
# <devices>
#   <iommu model='intel'>
#     <driver intremap='on'/>
#   </iommu>
# </devices>
# As per https://libvirt.org/formatdomain.html#iommu-devices

# Vendor ID from hosts't /sys/class/dmi/id/sys_vendor

SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor)"

if [[ -n "${PCI_DEVICES}" ]]; then
    re='([0-9,a-f,A-F]{2}):([0-9,a-f,A-F]{2})\.([0-9,a-f,A-F]{1})'
    for pci_device in ${PCI_DEVICES}; do
        [[ $pci_device =~ $re ]] || continue
        pci_bus=${BASH_REMATCH[1]}
        pci_slot=${BASH_REMATCH[2]}
        pci_function=${BASH_REMATCH[3]}
        HOST_DEVICES+="
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x${pci_bus}' slot='0x${pci_slot}' function='0x${pci_function}'/>
      </source>
    </hostdev>"
    done
    EXTRA_GRUBBY="vfio_pci.ids=${GPU_IDS}"
fi

cat <<EOF >${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}.xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <qemu:commandline>
     <qemu:arg value='-cpu'/>
     <qemu:arg value='host,hv_time,kvm=off,hv_vendor_id=null'/>

     <qemu:arg value='-device'/>
     <qemu:arg value='intel-iommu,intremap=on,caching-mode=on'/>
  </qemu:commandline>

  <name>${EDPM_COMPUTE_NAME}</name>
  <memory unit='GiB'>${EDPM_COMPUTE_RAM}</memory>
  <currentMemory unit='GiB'>${EDPM_COMPUTE_RAM}</currentMemory>
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
  <vcpu placement='static'>${EDPM_COMPUTE_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>
  <features>
    <ioapic driver='qemu'/>
    <kvm>
      <hidden state='on'/>
    </kvm>
    <hyperv>
      <vendor_id state='on' value='${SYS_VENDOR}'/>
    </hyperv>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <feature policy='disable' name='rdrand'/>
  </cpu>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK_FILEPATH}'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>
    <controller type='usb' index='0' model='qemu-xhci'>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </controller>
    <controller type='sata' index='0'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
    </controller>
    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='pci' index='1' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='1' port='0x10'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0' multifunction='on'/>
    </controller>
    <controller type='pci' index='2' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='2' port='0x11'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x1'/>
    </controller>
    <controller type='pci' index='3' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='3' port='0x12'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x2'/>
    </controller>
    <controller type='pci' index='4' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='4' port='0x13'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x3'/>
    </controller>
    <controller type='pci' index='5' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='5' port='0x14'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x4'/>
    </controller>
    <controller type='pci' index='6' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='6' port='0x15'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x5'/>
    </controller>
    ${HOST_DEVICES}
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='${HOME}'/>
      <target dir='dir0'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </filesystem>
    <interface type='${EDPM_COMPUTE_NETWORK_TYPE}'>
      <mac address='${MAC_ADDRESS}'/>
      <source ${EDPM_COMPUTE_NETWORK_TYPE}='${EDPM_COMPUTE_NETWORK}'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes'>
      <listen type='address'/>
    </graphics>
    <audio id='1' type='none'/>
    <video>
      <model type='cirrus' vram='16384' heads='1' primary='yes'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x0'/>
    </video>
    <memballoon model='none'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </rng>
  </devices>
</domain>
EOF

# Add additional networks to the domain XML
PCI_BUS_OFFSET=6
for (( idx=0; idx<$(echo "${EDPM_COMPUTE_ADDITIONAL_NETWORKS}" | jq --raw-output '. | length'); idx++ )); do
    mac_address=$(echo -n 52:54:00; dd bs=1 count=3 if=/dev/random 2>/dev/null | hexdump -v -e '/1 "-%02X"' | tr '-' ':')
    net_type=$(echo $EDPM_COMPUTE_ADDITIONAL_NETWORKS | jq --raw-output ".[$idx].type")
    net_name=$(echo $EDPM_COMPUTE_ADDITIONAL_NETWORKS | jq --raw-output ".[$idx].name")
    pci_bus=$(printf "0x%02x" $((${idx}+${PCI_BUS_OFFSET})))
    ADD_INTERFACES+="
        <interface type='${net_type}'>
            <mac address='${mac_address}'/>
            <source ${net_type}='${net_name}'/>
            <model type='virtio'/>
            <address type='pci' domain='0x0000' bus='${pci_bus}' slot='0x00' function='0x0'/>
        </interface>"
done
if [ ! -z "${ADD_INTERFACES}" ]; then
    if [ ! -e /usr/bin/xmlstarlet ]; then
        sudo dnf -y install /usr/bin/xmlstarlet
    fi
    mv ${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}.xml ${MY_TMP_DIR}/${EDPM_COMPUTE_NAME}.xml
    xmlstarlet edit --subnode '/domain/devices' --type text --name '' --value "${ADD_INTERFACES}" ${MY_TMP_DIR}/${EDPM_COMPUTE_NAME}.xml \
    | xmlstarlet unescape | xmlstarlet format --omit-decl \
    | tee ${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}.xml
fi

# Set network variables for firstboot script
IP=${IP:-"${EDPM_COMPUTE_NETWORK_IP%.*}.${IP_ADRESS_SUFFIX}"}
NETDEV=eth0
NETSCRIPT="/etc/sysconfig/network-scripts/ifcfg-${NETDEV}"
GATEWAY=${GATEWAY:-"${EDPM_COMPUTE_NETWORK_IP}"}
DNS=${DATAPLANE_DNS_SERVER}
PREFIX=24

cat <<EOF >${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}-firstboot.sh
PARTITION=\$(df / --output=source | grep -o "[[:digit:]]")
FS_PATH=\$(df / --output=source | grep -v Filesystem | tr -d \$PARTITION)
growpart \$FS_PATH \$PARTITION
xfs_growfs /

# create cloud-admin user
sudo useradd cloud-admin
echo 'cloud-admin     	ALL = (ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/cloud-admin
sudo chown root:root /etc/sudoers.d/cloud-admin
sudo chmod 0660 /etc/sudoers.d/cloud-admin

# don't kill processes after ssh logout
sudo loginctl enable-linger cloud-admin

# initialize authorized keys from root
if [ ! -e /home/cloud-admin/.ssh/authorized_keys ]; then
	sudo mkdir -p /home/cloud-admin/.ssh
	sudo chmod 0700 /home/cloud-admin/.ssh
	sudo cp /root/.ssh/authorized_keys /home/cloud-admin/.ssh/authorized_keys
	sudo chown -R cloud-admin: /home/cloud-admin/.ssh
	sudo chmod 0600 /home/cloud-admin/.ssh/authorized_keys
fi

# Set network for current session
nmcli device set eth0 managed yes
n=0
retries=6
while true; do
  nmcli device modify $NETDEV ipv4.addresses $IP/$PREFIX ipv4.gateway $GATEWAY ipv4.dns $DNS ipv4.method manual && break
  n="\$((n+1))"
  if (( n >= retries )); then
    echo "Failed to configure ipv4 address in $NETDEV."
    break
  fi
  sleep 5
done
# Set network to survive reboots
echo IPADDR=$IP >> $NETSCRIPT
echo PREFIX=$PREFIX >> $NETSCRIPT
echo GATEWAY=$GATEWAY >> $NETSCRIPT
echo DNS1=$DNS >> $NETSCRIPT
sed -i s/dhcp/none/g $NETSCRIPT
sed -i /PERSISTENT_DHCLIENT/d $NETSCRIPT

# Remove NVMe artifacts that are auto-generated when nvme-cli RPM is installed
rm -f /etc/nvme/hostid /etc/nvme/hostnqn

# Additional commands

EOF

touch $FIRSTBOOT_EXTRA
cat "$FIRSTBOOT_EXTRA" >> ${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}-firstboot.sh

chmod +x ${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}-firstboot.sh

if [ ! -f ${DISK_FILEPATH} ]; then
    if [ ! -f ${CRC_POOL}/${BASE_DISK_FILENAME} ]; then
        pushd ${CRC_POOL}
        curl -L -k ${EDPM_IMAGE_URL} -o ${BASE_DISK_FILENAME}
        popd
    fi
    qemu-img create -o backing_file=${CRC_POOL}/${BASE_DISK_FILENAME},backing_fmt=qcow2 -f qcow2 "${DISK_FILEPATH}" "${EDPM_COMPUTE_DISK_SIZE}G"
    if [[ ! -e /usr/bin/virt-customize ]]; then
        sudo dnf -y install /usr/bin/virt-customize
    fi
    virt-customize -a ${DISK_FILEPATH} \
        --root-password password:12345678 \
        --hostname ${EDPM_COMPUTE_NAME} \
        --firstboot ${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}-firstboot.sh \
        --run-command "systemctl disable cloud-init cloud-config cloud-final cloud-init-local" \
        --run-command "echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/99-root-login.conf" \
        --run-command "mkdir -p /root/.ssh; chmod 0700 /root/.ssh" \
        --run-command "ssh-keygen -f /root/.ssh/id_rsa -N ''" \
        --run-command "grubby --update-kernel ALL --args 'intel_iommu=on iommu=pt rd.driver.pre=vfio_pci ${EXTRA_GRUBBY} modules-load=vfio,vfio-pci,vfio_iommu_type1,vfio_pci_vfio_virqfd'" \
        --ssh-inject root:string:"$(cat $SSH_PUBLIC_KEY)" \
        --no-network \
        --selinux-relabel || rm -f ${DISK_FILEPATH}
    if [ ! -f ${DISK_FILEPATH} ]; then
        exit 1
    fi
fi

if ! virsh domuuid ${EDPM_COMPUTE_NAME}; then
    virsh define "${OUTPUT_DIR}/${EDPM_COMPUTE_NAME}.xml"
else
    echo "${EDPM_COMPUTE_NAME} already defined in libvirt, not redefining."
fi
if [ "$(virsh domstate ${EDPM_COMPUTE_NAME})" != "running" ]; then
    virsh start ${EDPM_COMPUTE_NAME}
else
    echo "${EDPM_COMPUTE_NAME} already running."
fi
