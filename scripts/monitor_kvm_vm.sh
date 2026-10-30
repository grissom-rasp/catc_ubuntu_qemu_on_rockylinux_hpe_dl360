#!/usr/bin/env bash
set -Eeuo pipefail

VM_NAME="${1:-catc-ubuntu-kvm}"
DURATION_MINUTES="${DURATION_MINUTES:-15}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"

if ! command -v virsh >/dev/null 2>&1; then
  echo "virsh is required to monitor the KVM guest." >&2
  exit 1
fi

END_EPOCH=$(( $(date +%s) + DURATION_MINUTES * 60 ))

while (( $(date +%s) < END_EPOCH )); do
  echo "===== $(date -Is) ====="
  virsh dominfo "${VM_NAME}" || true
  virsh domstate "${VM_NAME}" || true
  virsh domstats "${VM_NAME}" || true
  echo "--- libvirt logs ---"
  journalctl -u libvirtd --since "30 minutes ago" --no-pager | tail -n 50 || true
  echo "--- network status ---"
  ip addr show "${VM_NAME}" 2>/dev/null || true
  ss -tulpn | grep -E ':22|:5900|:16509' || true
  echo
  sleep "${SLEEP_SECONDS}"
done

echo "Monitoring complete. Review the ${VM_NAME} guest and host logs for CPU, memory, and networking stability."
