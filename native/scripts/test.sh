#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
native_dir="$(cd "$script_dir/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
args=(test --disable-xctest --package-path "$native_dir")
# Some standalone CLT releases ship Testing.framework without adding its search
# path to SwiftPM. Full Xcode toolchains discover their frameworks automatically.
framework_dir="$developer_dir/Library/Developer/Frameworks"
if [[ -d "$framework_dir/Testing.framework" ]]; then
  args+=(-Xswiftc -F -Xswiftc "$framework_dir" -Xlinker -rpath -Xlinker "$framework_dir")
  if [[ ! -d "$framework_dir/_Testing_Foundation.framework/Modules" ]]; then
    # CLT 26.2 omits the optional Foundation diagnostic overlay's Swift module.
    # Disable automatic overlay imports, not tests or assertions.
    args+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
  fi
fi
swift "${args[@]}"
