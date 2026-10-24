#!/bin/bash
# Compilation and unit tests only. No app launch, signing, mount or unmount.
set -euo pipefail
cd "$(dirname "$0")"
SDK26="${SDK26:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD_ROOT="${BUILD_ROOT:-$(mktemp -d /private/tmp/macdroidbridge-m0.XXXXXX)}"
mkdir -p "$BUILD_ROOT"
TARGET_ARCH="$(uname -m)"
test -d "$SDK26/System/Library/Frameworks/FSKit.framework"

# Xcode 27.1 cannot process bundle metadata with the external CLT 26.5 SDK.
# Build the native app/ExtensionKit targets using Xcode's registered SDK.
xcodebuild -project MacdroidBridgeHello.xcodeproj -scheme MacdroidBridgeHello \
  -configuration Debug -sdk macosx -derivedDataPath "$BUILD_ROOT/xcode" \
  CODE_SIGNING_ALLOWED=NO REGISTER_APP=NO build > "$BUILD_ROOT/xcode.log" 2>&1

# Independently compile AND link both complete executables using only SDK 26.5.
xcrun swiftc -sdk "$SDK26" -target "$TARGET_ARCH-apple-macos26.0" \
  -module-cache-path "$BUILD_ROOT/modules" -application-extension -parse-as-library \
  Sources/HelloFS/*.swift Extension/HelloExtension.swift -o "$BUILD_ROOT/extension-sdk26"
xcrun swiftc -sdk "$SDK26" -target "$TARGET_ARCH-apple-macos26.0" \
  -module-cache-path "$BUILD_ROOT/modules" -parse-as-library \
  Host/HelloHost.swift -o "$BUILD_ROOT/host-sdk26"

# Native SwiftPM honors the explicit Swift SDK arguments (its Xcode backend does not).
swift test --build-system native --package-path . --scratch-path "$BUILD_ROOT/tests" \
  -Xswiftc -sdk -Xswiftc "$SDK26" > "$BUILD_ROOT/tests.log" 2>&1
printf 'Build and tests passed. Artifacts and logs: %s\n' "$BUILD_ROOT"
