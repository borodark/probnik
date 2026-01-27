#!/usr/bin/env bash
set -euo pipefail

# Cross-compile Erlang/OTP for Android (arm64-v8a)
# Usage: ./android/build_otp.sh /path/to/otp-src
#
# Optional: Set OPENSSL_DIR to include crypto module
#   OPENSSL_DIR=/path/to/openssl ./android/build_otp.sh /path/to/otp-src

OTP_SRC="${1:-}"
if [[ -z "${OTP_SRC}" || ! -d "${OTP_SRC}" ]]; then
  echo "Usage: $0 /path/to/otp-src"
  echo ""
  echo "Optional environment variables:"
  echo "  OPENSSL_DIR  - Path to OpenSSL installation for crypto support"
  exit 1
fi

source "$(dirname "$0")/env.sh"

ANDROID_API=26
TOOLCHAIN="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="${TOOLCHAIN}/sysroot"

# Check for OpenSSL
OPENSSL_FLAGS=""
if [[ -n "${OPENSSL_DIR:-}" && -d "${OPENSSL_DIR}" ]]; then
  echo "==> Using OpenSSL from: ${OPENSSL_DIR}"
  OPENSSL_FLAGS="--with-ssl=${OPENSSL_DIR}"
  export ERL_XCOMP_SYSROOT="${SYSROOT}"
  export erl_xcomp_sysroot="${SYSROOT}"
  export CPPFLAGS="-I${OPENSSL_DIR}/include"
  export LDFLAGS="-L${OPENSSL_DIR}/lib"
  export SSL_CFLAGS="-I${OPENSSL_DIR}/include"
  export SSL_LDFLAGS="-L${OPENSSL_DIR}/lib"
  export SSL_LIBS="${OPENSSL_DIR}/lib/libssl.a ${OPENSSL_DIR}/lib/libcrypto.a"
  export LIBS="${OPENSSL_DIR}/lib/libssl.a ${OPENSSL_DIR}/lib/libcrypto.a"
else
  echo "==> No OPENSSL_DIR set - crypto module will be skipped"
  echo "    To enable crypto, first run: ./android/build_openssl.sh"
  echo "    Then: OPENSSL_DIR=\$PWD/_install/openssl-android-arm64 $0 $OTP_SRC"
  echo ""
fi

build_one() {
  local abi="$1"
  local host="$2"
  local cc="$3"
  local cxx="$4"
  local out="$5"
  local extra_flags="${6:-}"

  echo "==> Building OTP for ${abi}"
  pushd "${OTP_SRC}" >/dev/null

  ./configure \
    --host="${host}" \
    --build="$(./erts/autoconf/config.guess)" \
    --disable-jit \
    --disable-sctp \
    --without-et \
    --without-common_test \
    --without-syntax_tools \
    --without-javac \
    --without-snmp \
    --without-wx \
    --without-odbc \
    --without-jinterface \
    --without-termcap \
    --without-megaco \
    --without-debugger \
    --without-observer \
    --without-diameter \
    --without-radius \
    --without-cosEvent \
    --without-cosEventDomain \
    --without-cosFileTransfer \
    --without-cosNotification \
    --without-cosProperty \
    --without-cosTime \
    --without-cosTransactions \
    --enable-static-nifs \
    ${OPENSSL_FLAGS} \
    ${extra_flags} \
    CC="${cc}" CXX="${cxx}" AR="${TOOLCHAIN}/bin/llvm-ar" \
    RANLIB="${TOOLCHAIN}/bin/llvm-ranlib" STRIP="${TOOLCHAIN}/bin/llvm-strip"

  make -j$(nproc)
  make install DESTDIR="${out}"
  make clean

  popd >/dev/null
}

# Build for arm64-v8a only (skip armv7)
build_one "arm64-v8a" "aarch64-linux-android" \
  "${TOOLCHAIN}/bin/aarch64-linux-android${ANDROID_API}-clang" \
  "${TOOLCHAIN}/bin/aarch64-linux-android${ANDROID_API}-clang++" \
  "${PWD}/_install/android-arm64"

echo ""
echo "==> OTP build complete!"
echo "    Installation: ${PWD}/_install/android-arm64"
