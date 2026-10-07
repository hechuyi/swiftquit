#!/bin/bash
set -euo pipefail

# These regression executables use only Command Line Tools. SettingsTests uses
# a unique UserDefaults suite and removes it when finished.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_test_output="$(mktemp -d)"
trap 'rm -rf "$task_test_output"' EXIT

xcrun swiftc -swift-version 5 \
    "$task_root/Sources/SwiftQuit/QuitPolicy.swift" \
    "$task_root/Tests/PolicyTests.swift" \
    -o "$task_test_output/policy-tests"
"$task_test_output/policy-tests"

xcrun swiftc -swift-version 5 -framework AppKit \
    "$task_root/Sources/SwiftQuit/Settings.swift" \
    "$task_root/Tests/SettingsTests.swift" \
    -o "$task_test_output/settings-tests"
"$task_test_output/settings-tests"
