#!/usr/bin/env bash
set -euo pipefail

export ANDROID_SDK_ROOT="/home/io/Android/Sdk"
export ANDROID_NDK_ROOT="/home/io/Android/Sdk/ndk/25.2.9519653"
export JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"

export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
export PATH="$JAVA_HOME/bin:$PATH"
