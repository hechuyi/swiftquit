#!/bin/bash
set -euo pipefail

# Command Line Tools are sufficient; this build does not use Interface Builder.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="${1:-$task_root/build}"
task_mode="${2:-native}"
task_app="$task_output/Swift Quit.app"
task_temp="$(mktemp -d)"
trap 'rm -rf "$task_temp"' EXIT
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/Resources/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
cp "$task_root/LICENSE" "$task_app/Contents/Resources/LICENSE"

if [[ "$task_mode" == "universal" ]]; then
    task_architectures=(arm64 x86_64)
elif [[ "$task_mode" == "native" ]]; then
    task_architectures=("$(uname -m)")
else
    printf 'Usage: %s [output-directory] [native|universal]\n' "$0" >&2
    exit 2
fi

task_sources=("$task_root"/Sources/SwiftQuit/*.swift)
task_binaries=()
for task_architecture in "${task_architectures[@]}"; do
    task_binary="$task_temp/SwiftQuit-$task_architecture"
    xcrun swiftc -O -swift-version 5 -module-name SwiftQuit \
        -target "$task_architecture-apple-macosx13.0" \
        -framework AppKit -framework ApplicationServices -framework ServiceManagement \
        "${task_sources[@]}" -o "$task_binary"
    task_binaries+=("$task_binary")
done
if [[ ${#task_binaries[@]} -eq 1 ]]; then
    cp "${task_binaries[0]}" "$task_app/Contents/MacOS/Swift Quit"
else
    xcrun lipo -create "${task_binaries[@]}" -output "$task_app/Contents/MacOS/Swift Quit"
fi

# Local builds receive a normal ad-hoc signature. A changed binary may need its
# Accessibility permission renewed; Developer ID distribution uses its own identity.
task_identity="${SIGNING_IDENTITY:--}"
if [[ "$task_identity" == "-" ]]; then
    codesign --force --sign - --identifier onebadidea.Swift-Quit \
        --options runtime "$task_app"
else
    codesign --force --sign "$task_identity" --identifier onebadidea.Swift-Quit \
        --options runtime --timestamp "$task_app"
fi
codesign --verify --deep --strict "$task_app"
printf '%s\n' "$task_app"
