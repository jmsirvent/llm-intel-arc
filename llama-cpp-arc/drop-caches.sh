#!/usr/bin/env bash
# drop-caches.sh — Release system RAM between llama-bench runs.
#
# What this script does:
#   1. Drops Linux page cache, dentries and inodes (echo 3 > /proc/sys/vm/drop_caches)
#   2. Cycles swap to recover any swap-backed pages
# Both steps require sudo.
#
# What this script does NOT do:
#   - It does not free GPU memory. The xe driver (Lunar Lake / Xe2) manages its
#     own memory pool independently of the Linux page cache. When llama-server
#     exits, the xe driver retains the allocated pages in the GPU pool rather
#     than returning them to the system immediately. drop_caches has no effect
#     on this pool. GPU memory shown by xpu-smi after stopping the server
#     includes those retained pages plus the Wayland compositor (~1-2 GiB,
#     permanent while a desktop session is running).
#   - To fully recover GPU memory: reboot. There is no userspace command to
#     force the xe driver to flush its pool without reloading the kernel module.

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [-h]"
  echo ""
  echo "Release GPU and system memory between llama-bench runs."
  echo "Requires sudo for cache drop and swap cycle."
  echo ""
  echo "What it does:"
  echo "  1. sudo echo 3 > /proc/sys/vm/drop_caches  (page/dentry/inode cache)"
  echo "  2. sudo swapoff -a && swapon -a             (swap cycle)"
  echo "  Shows RAM and GPU memory before and after."
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
sep()   { printf '%.0s─' {1..50}; echo; }

mem_available_gib() {
  awk '/^MemAvailable:/ { printf "%.1f GiB available", $2/1024/1024 }' /proc/meminfo
}

gpu_mem_used_gib() {
  # xpu-smi stats uses | as table borders: "| GPU Memory Used (MiB) | 17637 |"
  # $NF is the trailing empty field after the last |; value is at $(NF-1)
  xpu-smi stats -d 0 2>/dev/null \
    | awk -F'|' '/GPU Memory Used/ {
        gsub(/ /, "", $(NF-1))
        printf "%.1f GiB used\n", $(NF-1) / 1024
      }' \
    | head -1 || echo "unavailable"
}

sep
bold "Memory before:"
printf "  RAM : %s\n" "$(mem_available_gib)"
printf "  GPU : %s\n" "$(gpu_mem_used_gib)"
sep

# Drop page cache, dentries and inodes (3 = all three combined)
sudo sync
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
printf "  ✓ Page/dentry/inode cache dropped\n"

# Cycle swap to release swap-backed pages back to RAM
sudo swapoff -a
sudo swapon -a
printf "  ✓ Swap cycled\n"

sep
bold "Memory after:"
printf "  RAM : %s\n" "$(mem_available_gib)"
printf "  GPU : %s\n" "$(gpu_mem_used_gib)"
sep
green "Done."
