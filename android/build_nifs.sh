#!/usr/bin/env bash
set -euo pipefail

# Cross-compile Scenic NIFs for Android
# Run after build_otp.sh

source "$(dirname "$0")/env.sh"

ANDROID_API=26
TOOLCHAIN="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

build_scenic_nifs() {
  local abi="$1"
  local target="$2"
  local otp_install="$3"
  local out_dir="$4"

  echo "==> Building Scenic NIFs for ${abi}"

  local cc="${TOOLCHAIN}/bin/${target}${ANDROID_API}-clang"
  local erl_include="${otp_install}/usr/local/lib/erlang/usr/include"
  local erl_lib="${otp_install}/usr/local/lib/erlang/usr/lib"

  mkdir -p "${out_dir}"

  for src in bitmap line matrix; do
    echo "  Compiling ${src}.c"
    ${cc} -c -fPIC -O2 -Wall -std=c99 \
      -I"${erl_include}" \
      -o "${out_dir}/${src}.o" \
      "${PROJECT_ROOT}/deps/scenic/c_src/${src}.c"

    ${cc} -shared \
      -L"${erl_lib}" \
      -o "${out_dir}/${src}.so" \
      "${out_dir}/${src}.o"

    rm "${out_dir}/${src}.o"
  done

  echo "  NIFs built: $(ls ${out_dir}/*.so)"
}

# Build for ARM64 only
build_scenic_nifs "arm64-v8a" "aarch64-linux-android" \
  "${PROJECT_ROOT}/_install/android-arm64" \
  "${PROJECT_ROOT}/_build/android/nifs/arm64-v8a"

echo ""
echo "==> Scenic NIFs built for Android"
echo "    arm64-v8a: ${PROJECT_ROOT}/_build/android/nifs/arm64-v8a/"
