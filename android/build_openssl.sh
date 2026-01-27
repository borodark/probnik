#!/bin/bash
set -e

# Build OpenSSL for Android arm64-v8a
# Requires: Android NDK, wget/curl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source environment
source "$SCRIPT_DIR/env.sh"

OPENSSL_VERSION="3.2.0"
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
BUILD_DIR="$PROJECT_ROOT/_build/openssl-android"
INSTALL_DIR="$PROJECT_ROOT/_install/openssl-android-arm64"

# NDK paths
TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
API_LEVEL=26

echo "==> Building OpenSSL $OPENSSL_VERSION for Android arm64-v8a"
echo "    NDK: $ANDROID_NDK_ROOT"
echo "    Install: $INSTALL_DIR"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Download if needed
if [ ! -f "openssl-${OPENSSL_VERSION}.tar.gz" ]; then
    echo "==> Downloading OpenSSL..."
    wget -q "$OPENSSL_URL"
fi

# Extract
if [ ! -d "openssl-${OPENSSL_VERSION}" ]; then
    echo "==> Extracting..."
    tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
fi

cd "openssl-${OPENSSL_VERSION}"

# Clean previous build
if [ -f Makefile ]; then
    make clean 2>/dev/null || true
fi

# Configure for Android
echo "==> Configuring OpenSSL for Android arm64..."

export ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT"
export PATH="$TOOLCHAIN/bin:$PATH"

./Configure android-arm64 \
    -D__ANDROID_API__=$API_LEVEL \
    --prefix="$INSTALL_DIR" \
    --openssldir="$INSTALL_DIR/ssl" \
    no-shared \
    no-tests \
    no-ui-console

# Build
echo "==> Building OpenSSL (this may take a few minutes)..."
make -j$(nproc)

# Install
echo "==> Installing..."
make install_sw

echo ""
echo "==> OpenSSL built successfully!"
echo "    Headers: $INSTALL_DIR/include"
echo "    Libraries: $INSTALL_DIR/lib"
echo ""
echo "Now rebuild OTP with OpenSSL:"
echo "    OPENSSL_DIR=$INSTALL_DIR ./android/build_otp.sh /path/to/otp-src"
