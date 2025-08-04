#!/bin/bash
set -euo pipefail

# Read version and normalize
VERSION=$(cat VERSION | tr -d '[:space:]')
TARBALL="wasm-libs-v$VERSION.tar.gz"
SHAFILE="$TARBALL.sha256"
MANIFEST="wasm-libs-v$VERSION.json"

# Create output directory
mkdir -p dist

# Create tarball of include/ and lib/
tar -czf "dist/$TARBALL" include/ lib/

# Compute SHA-256 checksum (without path prefix)
(cd dist && sha256sum "$TARBALL" > "$SHAFILE")

# Extract just the hash for manifest
SHA256=$(awk '{print $1}' "dist/$SHAFILE")

# Create JSON manifest
cat > "dist/$MANIFEST" <<EOF
{
  "version": "$VERSION",
  "tarball": "$TARBALL",
  "sha256": "$SHA256",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo "✅ Created: dist/$TARBALL"
echo "✅ Created: dist/$SHAFILE"
echo "✅ Created: dist/$MANIFEST"

