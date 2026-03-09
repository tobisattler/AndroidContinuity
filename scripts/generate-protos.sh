#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROTO_DIR="$ROOT_DIR/shared/proto"

PROTO_FILES=(
  "$PROTO_DIR/continuity/v1/common.proto"
  "$PROTO_DIR/continuity/v1/pairing.proto"
  "$PROTO_DIR/continuity/v1/transfer.proto"
)

# --- Check prerequisites ---
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found. Install with: $2"
    exit 1
  fi
}

check_command protoc "brew install protobuf"
check_command protoc-gen-swift "brew install swift-protobuf"

# gRPC Swift 2.x installs as protoc-gen-grpc-swift-2
GRPC_SWIFT_PLUGIN=""
if command -v protoc-gen-grpc-swift &>/dev/null; then
  GRPC_SWIFT_PLUGIN="protoc-gen-grpc-swift"
elif command -v protoc-gen-grpc-swift-2 &>/dev/null; then
  GRPC_SWIFT_PLUGIN="protoc-gen-grpc-swift-2"
else
  echo "ERROR: 'protoc-gen-grpc-swift' or 'protoc-gen-grpc-swift-2' not found."
  echo "Install with: brew install protoc-gen-grpc-swift"
  exit 1
fi
echo "Using gRPC Swift plugin: $GRPC_SWIFT_PLUGIN"

# --- Android ---
echo "=== Generating Android proto files ==="
ANDROID_PROTO_DIR="$ROOT_DIR/android/app/src/main/proto"
mkdir -p "$ANDROID_PROTO_DIR/continuity/v1"
cp "$PROTO_DIR/continuity/v1/"*.proto "$ANDROID_PROTO_DIR/continuity/v1/"
echo "[OK] Android protos copied to $ANDROID_PROTO_DIR"
echo "     Gradle protobuf plugin handles Java/Kotlin codegen at build time."

# --- macOS (Swift) ---
echo ""
echo "=== Generating Swift proto files ==="
SWIFT_OUT="$ROOT_DIR/macos/AndroidContinuity/Sources/Generated"
mkdir -p "$SWIFT_OUT"

protoc \
  --proto_path="$PROTO_DIR" \
  --plugin="protoc-gen-grpc-swift=$(command -v "$GRPC_SWIFT_PLUGIN")" \
  --swift_out="$SWIFT_OUT" \
  --swift_opt=Visibility=Public \
  --grpc-swift_out="$SWIFT_OUT" \
  --grpc-swift_opt=Visibility=Public,Client=true,Server=true \
  "${PROTO_FILES[@]}"

echo "[OK] Swift proto files generated in $SWIFT_OUT"
echo ""

# --- Summary ---
echo "=== Generated files ==="
echo "Android (copied for Gradle plugin):"
ls -1 "$ANDROID_PROTO_DIR/continuity/v1/"*.proto 2>/dev/null | sed 's/^/  /'
echo ""
echo "macOS (protoc-generated Swift):"
find "$SWIFT_OUT" -name "*.swift" -type f | sed 's/^/  /'
echo ""
echo "Done!"
