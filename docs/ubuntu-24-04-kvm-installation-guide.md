# Rocky Linux DL360 + Ubuntu 24.04 LTS headless KVM installation guide

This repository keeps the steps needed to replace an existing Ubuntu 26.04 LTS Server QEMU/KVM guest on an HP ProLiant DL360 Gen10+ with a headless Ubuntu 24.04 LTS Server guest that runs under Rocky Linux.

## Target VM specification

- Guest OS: Ubuntu 24.04 LTS Server (cloud image, headless)
- Guest name: `catc-ubuntu-kvm`
- vCPU: 48
- Memory: 64 GiB
- Disk: 300 GiB virtual hard disk
- Network: bridged network on `br0` in the `192.168.0.0/24` subnet with DHCP
- Admin user: `catc_ubuntu_kvm`
- Password: `P@ssw0rd.Nms`
- SSH: enabled permanently and password auth enabled

## Host preparation

1. Connect as root to the remote DL360 host running Rocky Linux.
2. Ensure the host has the virtualization stack installed:

```bash
sudo dnf install -y qemu-kvm qemu-img libvirt virt-install guestfs-tools cloud-image-utils dnsmasq bridge-utils
sudo systemctl enable --now libvirtd
```

3. Confirm the bridge interface for the guest. In this environment the VM is attached to `br0`, which is connected to the main uplink so it can obtain a DHCP address from the `192.168.0.0/24` network.

```bash
ip link show br0
ip addr show br0
```

4. If `br0` does not exist, create it and attach the physical NIC. On Rocky Linux with NetworkManager, the pattern is:

```bash
sudo nmcli connection add type bridge ifname br0 con-name br0
sudo nmcli connection add type bridge-slave ifname eth0 master br0 con-name br0-eth0
sudo nmcli connection up br0
```

Replace `eth0` with the actual uplink NIC name discovered by `ip link`.

## Remove the previous Ubuntu 26.04 KVM guest

Use the following to remove the old cloud/QEMU/KVM guest if it already exists:

```bash
sudo virsh list --all
sudo virsh shutdown catc-ubuntu-kvm || true
sudo virsh destroy catc-ubuntu-kvm || true
sudo virsh undefine --nvram catc-ubuntu-kvm --remove-all-storage || true
sudo rm -f /var/lib/libvirt/images/catc-ubuntu-kvm.qcow2
```

## Deploy the Ubuntu 24.04 cloud image VM

The repository includes an automation script that performs the install safely on Rocky Linux.

```bash
cd /path/to/repository
sudo bash scripts/install_ubuntu_24_kvm.sh
```

The script performs the following actions:

- installs the required KVM packages
- creates or reuses the host bridge `br0`
- removes any stale guest definition and disk image
- writes a cloud-init configuration for the Ubuntu guest
- downloads the Ubuntu 24.04 Server cloud image
- creates a 48 vCPU, 64 GiB, 300 GiB VM
- connects the guest to `br0` using DHCP on the `192.168.0.0/24` subnet
- configures the admin user `catc_ubuntu_kvm` with password `P@ssw0rd.Nms`
- enables SSH and password authentication in the guest

## Cloud-init configuration details

The install uses the Ubuntu cloud-config format to provision the guest. The login for SSH is:

- user: `catc_ubuntu_kvm`
- password: `P@ssw0rd.Nms`

The cloud-init configuration ensures that SSH remains enabled on every reboot by adding the following steps:

```yaml
users:
  - name: catc_ubuntu_kvm
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "P@ssw0rd.Nms"
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
chpasswd:
  expire: false
  list: |
    catc_ubuntu_kvm:P@ssw0rd.Nms
ssh_pwauth: true
runcmd:
  - [ sh, -c, "systemctl enable --now ssh" ]
```

## Post-install verification

1. Confirm the guest is active and attached to the bridge:

```bash
sudo virsh list --all
sudo virsh dominfo catc-ubuntu-kvm
sudo virsh domiflist catc-ubuntu-kvm
```

2. Confirm the guest receives a DHCP address in the `192.168.0.0/24` range:

```bash
sudo virsh net-dhcp-leases default
sudo virsh net-dhcp-leases catc-ubuntu-kvm-net
```

3. Validate SSH access from the management network:

```bash
ssh catc_ubuntu_kvm@<ubuntu-guest-ip>
```

4. Verify the host and guest are healthy with standard system checks:

```bash
sudo virsh domstate catc-ubuntu-kvm
sudo systemctl status libvirtd
sudo journalctl -u libvirtd -n 200 --no-pager
```

## Monitoring for 15 minutes and log review

Launch the monitoring script after the VM is online:

```bash
sudo bash scripts/monitor_kvm_vm.sh catc-ubuntu-kvm
```

The script captures `virsh` state, `journalctl` output, and network checks for 15 minutes to help confirm that the Rocky Linux host and the Ubuntu guest remain healthy.

## Operational recommendations and optimizations

For the Rocky Linux KVM host:

- Run the host with the `virtual-host` tuned profile:

```bash
sudo tuned-adm profile virtual-host
```

- Enable `irqbalance` and keep the `libvirtd` service healthy.
- Keep the guest on a dedicated bridge `br0` rather than NAT unless a dedicated isolated network is required.
- Consider enabling `vm.swappiness=1` or setting a low swap policy for the host if memory pressure is observed.
- Review `libvirt` logs for I/O and PCI passthrough warnings, and keep the `qemu-kvm` package updated.

For the Ubuntu guest:

- Keep `openssh-server` and `qemu-guest-agent` installed and updated.
- Minimize unnecessary daemons in the headless VM.
- Disable unnecessary logging noise and retain the systemd journal.
- Use a read-only or minimal package set for the headless guest to reduce CPU and I/O overhead.

## Final notes

This design is intentionally simple and reliable for the HP ProLiant DL360 Gen10+ platform:

- the Rocky Linux host runs the hypervisor
- the Ubuntu guest is provisioned from the official cloud image
- the guest is headless, networked through the host bridge, and ready for SSH access
- the configuration is repeatable and suitable for an admin-managed lab or production environment

