# Build environment for the omega APK. Toolchain and entrypoint only: the patch
# series and build scripts are cloned at run time so changing one does not mean
# rebuilding several gigabytes of Android SDK.
#
# No KODI_* value is baked in; they all arrive as env vars at run time, so this
# image is as public as the repository.
FROM ubuntu:24.04

# openjdk-17-jdk by name, not default-jdk: omega ships the Gradle 8.3 wrapper,
# which supports up to Java 20, and a newer JDK fails at APK packaging, after
# the whole build. rsync is this repo's requirement, not Kodi's.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      autoconf bison build-essential ca-certificates ccache curl flex gawk git \
      gperf lib32stdc++6 lib32z1 lib32z1-dev libcurl4-openssl-dev \
      openjdk-17-jdk rsync unzip zip zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:$PATH"

# Ubuntu 24.04 ships a user at uid 1000, so it has to go before useradd. 1000
# specifically, not any free uid: the cluster pins runAsUser to it.
RUN userdel -r ubuntu \
 && groupadd -g 1000 builder \
 && useradd -u 1000 -g 1000 -m -d /home/builder -s /bin/bash builder

# Own SDK root. tools/depends/configure.ac:589 picks build-tools with
# `sort -V | tail -n 1`, so a root shared with the master target hands this
# build the wrong ones with no way to ask for an older version.
ENV NDK_SDK=/opt/android-sdk-omega
ENV NDK_VERSION=21.4.7075529
ENV NDK_PATH=/opt/android-sdk-omega/ndk/21.4.7075529

# cmdline-tools;latest is required: configure.ac wants an sdkmanager inside the
# SDK root it is given.
#
# The chown has to be in this layer. In a separate RUN it makes the layer a full
# copy of every file it touches, which put four gigabytes of SDK in the image
# twice.
RUN mkdir -p "$NDK_SDK" \
 && curl -fsSL -o /tmp/cmdline-tools.zip \
      https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
 && unzip -q /tmp/cmdline-tools.zip -d "$NDK_SDK" \
 && rm /tmp/cmdline-tools.zip \
 && yes 2>/dev/null | "$NDK_SDK/cmdline-tools/bin/sdkmanager" --sdk_root="$NDK_SDK" --licenses >/dev/null \
 && "$NDK_SDK/cmdline-tools/bin/sdkmanager" --sdk_root="$NDK_SDK" \
      "cmdline-tools;latest" platform-tools \
      "platforms;android-34" "build-tools;33.0.1" "ndk;$NDK_VERSION" \
 && rm -rf /root/.android \
 && chown -R 1000:1000 "$NDK_SDK"

# No keystore in the image. A key generated per image build gives every image a
# different signing identity, and Android then refuses the upgrade with
# INSTALL_FAILED_UPDATE_INCOMPATIBLE; uninstalling first costs the device its
# texture cache. The key arrives at run time via KODI_ANDROID_STORE_FILE.
ENV HOME=/home/builder
RUN mkdir -p "$HOME/.android" && chown -R 1000:1000 "$HOME"

# Large and disposable, on whatever volume the caller mounts. Not under $HOME,
# which a mount there would shadow.
ENV TARBALLS=/mnt/buildram/tarballs
WORKDIR /mnt/buildram

COPY build-apk.sh /usr/local/bin/build-apk
RUN chmod 0755 /usr/local/bin/build-apk

# Unprivileged from here; nothing at run time needs root. The volume at WORKDIR
# must be writable by this uid, which is the caller's job (fsGroup: 1000).
USER 1000:1000

ENTRYPOINT ["/usr/local/bin/build-apk"]
