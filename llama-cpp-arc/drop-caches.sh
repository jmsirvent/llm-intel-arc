#!/usr/bin/env bash
# drop-caches.sh — Release GPU and system memory between llama-bench runs.
#
# The xe driver retains GPU memory pages after a model is unloaded and does
# not return them to the system until explicitly asked. This script:
#   1. Drops page cache, dentries and inodes (echo 3 > /proc/sys/vm/drop_caches)
#   2. Cycles swap to recover any swap-backed pages
# Both require sudo. Run between model loads to get a clean memory baseline.

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

mem_available_gb() {
  awk '/^MemAvailable:/ { printf "%.1f GB", $2/1024/1024 }' /proc/meminfo
}

gpu_mem_used_mb() {
  xpu-smi stats -d 0 2>/dev/null \
    | awk '/Memory Used/ { print $NF " MiB used" }' \
    | head -1 || echo "xpu-smi unavailable"
}

sep
bold "Memory before:"
printf "  RAM : %s\n" "$(mem_available_gb)"
printf "  GPU : %s\n" "$(gpu_mem_used_mb)"
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
printf "  RAM : %s\n" "$(mem_available_gb)"
printf "  GPU : %s\n" "$(gpu_mem_used_mb)"
sep
green "Done."
