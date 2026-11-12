# Toolchain image for building the RustDesk Android client locally.
# Every version below is copied from upstream CI at tag 1.5.0 (unchanged at 1.5.3):
#   .github/workflows/bridge.yml        (bridge codegen: Rust 1.75, flutter_rust_bridge 1.80.1, Flutter 3.22.3)
#   .github/workflows/flutter-build.yml (job build-rustdesk-android: NDK r28c, cargo-ndk 3.1.2,
#                                        Flutter 3.24.5, vcpkg 9e593bb18ea69cc5095e012465dcd675a822ed0d)
# Build:  docker build -t emilli/rustdesk-android-toolchain:1.5.0 deploy/rustdesk-android
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf automake bash ca-certificates clang cmake curl file g++ g++-multilib gcc gcc-multilib git libc6-dev \
      libclang-dev libgtk-3-dev libssl-dev libtool llvm-dev make nasm ninja-build openjdk-17-jdk-headless \
      perl pkg-config python3 tree unzip wget xz-utils zip \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_HOME=/opt/android-ndk-r28c \
    ANDROID_NDK_ROOT=/opt/android-ndk-r28c \
    VCPKG_ROOT=/opt/vcpkg \
    FLUTTER_ROOT=/opt/flutter-3.24.5 \
    PUB_CACHE=/opt/pub-cache \
    CARGO_BUILD_JOBS=10 \
    VCPKG_MAX_CONCURRENCY=10
ENV PATH=/opt/cargo/bin:/opt/flutter-3.24.5/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:$PATH

# Rust 1.75 (upstream pins it, see rustdesk discussion 7503) and the two Android targets.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.75 \
      -c rustfmt -t aarch64-linux-android -t armv7-linux-androideabi -t x86_64-linux-android
RUN cargo install cargo-ndk --version 3.1.2 --locked \
 && cargo install cargo-expand --version 1.0.95 --locked \
 && cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked

# Android SDK command line tools, platform 36 (compileSdk in flutter/android/app/build.gradle) and NDK r28c.
RUN mkdir -p /opt/android-sdk/cmdline-tools \
 && curl -fsSL -o /tmp/clt.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
 && unzip -q /tmp/clt.zip -d /opt/android-sdk/cmdline-tools \
 && mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest \
 && rm /tmp/clt.zip \
 && (yes | sdkmanager --licenses > /dev/null) \
 && sdkmanager "platform-tools" "platforms;android-36" "build-tools;35.0.0" "build-tools;36.0.0" > /dev/null
RUN curl -fsSL -o /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r28c-linux.zip \
 && unzip -q /tmp/ndk.zip -d /opt \
 && rm /tmp/ndk.zip

# Flutter 3.24.5 for the APK build, 3.22.3 only for bridge generation (as upstream does).
RUN for v in 3.24.5 3.22.3; do \
      curl -fsSL -o /tmp/flutter.tar.xz https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${v}-stable.tar.xz \
      && mkdir -p /opt/flutter-${v} && tar -xJf /tmp/flutter.tar.xz -C /opt/flutter-${v} --strip-components=1 \
      && rm /tmp/flutter.tar.xz \
      && /opt/flutter-${v}/bin/flutter config --no-analytics > /dev/null \
      && /opt/flutter-${v}/bin/flutter --version ; \
    done \
 && /opt/flutter-3.24.5/bin/flutter precache --android > /dev/null

# vcpkg at the commit upstream pins (also the manifest baseline).
RUN git clone https://github.com/microsoft/vcpkg /opt/vcpkg \
 && git -C /opt/vcpkg checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d \
 && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

WORKDIR /work
