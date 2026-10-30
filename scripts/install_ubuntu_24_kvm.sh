#!/usr/bin/env bash
set -Eeuo pipefail

VM_NAME="${VM_NAME:-catc-ubuntu-kvm}"
VM_MEMORY_MB="${VM_MEMORY_MB:-65536}"
VM_VCPUS="${VM_VCPUS:-48}"
VM_DISK_GB="${VM_DISK_GB:-300}"
VM_BRIDGE="${VM_BRIDGE:-br0}"
VM_USER="${VM_USER:-catc_ubuntu_kvm}"
VM_PASSWORD="${VM_PASSWORD:?set VM_PASSWORD in the environment}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"

DISK_PATH="${IMAGE_DIR}/${VM_NAME}.qcow2"
USER_DATA_PATH="${IMAGE_DIR}/${VM_NAME}-user-data"
META_DATA_PATH="${IMAGE_DIR}/${VM_NAME}-meta-data"
LOG_PREFIX="[ubuntu24-kvm]"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "${LOG_PREFIX} This script must be run as root on the Rocky Linux host." >&2
    exit 1
  fi
}

install_packages() {
  echo "${LOG_PREFIX} Ensuring KVM and virtualization packages are present."
  dnf install -y qemu-kvm qemu-img libvirt virt-install guestfs-tools cloud-image-utils dnsmasq bridge-utils >/dev/null
  systemctl enable --now libvirtd
  systemctl enable --now virtqemud
}

ensure_bridge() {
  if ip link show "${VM_BRIDGE}" >/dev/null 2>&1; then
    echo "${LOG_PREFIX} Bridge ${VM_BRIDGE} already exists."
    return
  fi

  local iface
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1 {print $5; exit}')"
  if [[ -z "${iface}" ]]; then
    echo "${LOG_PREFIX} No active NIC was detected; cannot create the bridge automatically." >&2
    exit 1
  fi

  echo "${LOG_PREFIX} Creating bridge ${VM_BRIDGE} on interface ${iface}."
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection add type bridge ifname "${VM_BRIDGE}" con-name "${VM_BRIDGE}" >/dev/null
    nmcli connection add type bridge-slave ifname "${iface}" master "${VM_BRIDGE}" con-name "${VM_BRIDGE}-${iface}" >/dev/null
    nmcli connection up "${VM_BRIDGE}" >/dev/null
  else
    cat > "/etc/sysconfig/network-scripts/ifcfg-${VM_BRIDGE}" <<EOF
DEVICE=${VM_BRIDGE}
TYPE=Bridge
ONBOOT=yes
BOOTPROTO=dhcp
NM_CONTROLLED=yes
EOF
    cat > "/etc/sysconfig/network-scripts/ifcfg-${iface}" <<EOF
DEVICE=${iface}
TYPE=Ethernet
ONBOOT=yes
BOOTPROTO=none
BRIDGE=${VM_BRIDGE}
NM_CONTROLLED=yes
EOF
    ifup "${VM_BRIDGE}" || true
    ifup "${iface}" || true
  fi
}

remove_existing_vm() {
  if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    echo "${LOG_PREFIX} Removing the existing VM definition named ${VM_NAME}."
    virsh shutdown "${VM_NAME}" >/dev/null 2>&1 || true
    virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
    virsh undefine "${VM_NAME}" --nvram >/dev/null 2>&1 || true
  fi

  rm -f "${DISK_PATH}"
  rm -f "${USER_DATA_PATH}"
  rm -f "${META_DATA_PATH}"
}

create_cloud_init() {
  mkdir -p "${IMAGE_DIR}"

  cat > "${USER_DATA_PATH}" <<EOF
#cloud-config
users:
  - default
  - name: ${VM_USER}
    gecos: CATC Ubuntu KVM admin
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "${VM_PASSWORD}"
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
chpasswd:
  expire: false
  list: |
    ${VM_USER}:${VM_PASSWORD}
ssh_pwauth: true
package_update: true
packages:
  - openssh-server
  - qemu-guest-agent
write_files:
  - path: /etc/ssh/sshd_config.d/99-password-auth.conf
    permissions: "0644"
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      PubkeyAuthentication yes
runcmd:
  - [ sh, -c, "systemctl enable --now ssh" ]
  - [ sh, -c, "systemctl enable --now qemu-guest-agent" ]
  - [ sh, -c, "sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true" ]
  - [ sh, -c, "sed -i 's/^#\\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config || true" ]
  - [ sh, -c, "systemctl restart ssh || systemctl restart sshd" ]
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
EOF

  cat > "${META_DATA_PATH}" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF
}

download_image() {
  if [[ ! -f "${DISK_PATH}" ]]; then
    echo "${LOG_PREFIX} Downloading the Ubuntu 24.04 server cloud image."
    curl -fsSLo "${IMAGE_DIR}/ubuntu-24.04-server-cloudimg-amd64.img" "${IMAGE_URL}"
    qemu-img convert -O qcow2 "${IMAGE_DIR}/ubuntu-24.04-server-cloudimg-amd64.img" "${DISK_PATH}"
    qemu-img resize "${DISK_PATH}" "${VM_DISK_GB}G"
  fi
}

create_vm() {
  echo "${LOG_PREFIX} Creating the headless Ubuntu 24.04 VM on the DL360 host."
  virt-install \
    --connect qemu:///system \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY_MB}" \
    --vcpus "${VM_VCPUS}" \
    --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
    --import \
    --osinfo ubuntu24.04 \
    --network "bridge=${VM_BRIDGE},model=virtio" \
    --graphics none \
    --console "pty,target_type=virtio" \
    --cloud-init "user-data=${USER_DATA_PATH},meta-data=${META_DATA_PATH}" \
    --noautoconsole \
    --check path_in_use=off
}

verify_vm() {
  echo "${LOG_PREFIX} Checking the VM definition and power status."
  virsh dominfo "${VM_NAME}"
  virsh domstate "${VM_NAME}"
  virsh net-list --all
}

main() {
  require_root
  install_packages
  ensure_bridge
  remove_existing_vm
  create_cloud_init
  download_image
  create_vm
  verify_vm
}

main "$@"
