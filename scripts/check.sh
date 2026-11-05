#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
check_dir="$(mktemp -d /tmp/bgMon-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc Sources/bgMon/CPUSampler.swift Tests/CPU/main.swift -o "$check_dir/cpu"
"$check_dir/cpu"
swiftc Sources/bgMon/ListeningPorts.swift Tests/Ports/main.swift -o "$check_dir/ports"
"$check_dir/ports"
swiftc Sources/bgMon/WarningIgnoreList.swift Tests/WarningIgnoreList/main.swift -o "$check_dir/warning-ignore-list"
"$check_dir/warning-ignore-list"
