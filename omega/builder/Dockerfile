# Build environment for the omega APK, so the build runs the same way in the
# cluster as it did on a workstation.
#
# Only the environment and the entrypoint live here. The patch series and the
# build scripts are cloned at run time, because those are what actually change:
# baking them would mean rebuilding several gigabytes of Android SDK to alter
# one patch.
#
# Nothing device-specific is baked in. Every KODI_* value arrives as an
# environment variable when the build runs, so this image stays as public as
# the repository it is built from.
FROM ubuntu:24.04

# From PREREQUISITES.md. openjdk-17-jdk by name rather than default-jdk: the
# omega target ships the Gradle 8.3 wrapper, which supports up to Java 20, and
# a too-new JDK fails at APK packaging after the whole build has already run.
# rsync is not upstream Kodi's requirement but this repo's: build-kodi.sh syncs
# the source tree on every run.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      autoconf bison build-essential ca-certificates ccache curl flex gawk git \
      gperf lib32stdc++6 lib32z1 lib32z1-dev libcurl4-openssl-dev \
      openjdk-17-jdk rsync unzip zip zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:$PATH"

# uid 1000 is already taken. Ubuntu ships a default "ubuntu" user at 1000 from
# 24.04 onwards, where earlier releases left it free, so useradd collides
# unless that one goes first. 1000 rather than any free uid because the
# cluster's securityContext pins runAsUser to it.
RUN userdel -r ubuntu \
 && groupadd -g 1000 builder \
 && useradd -u 1000 -g 1000 -m -d /home/builder -s /bin/bash builder

# Its own SDK root, matching the layout PREREQUISITES.md insists on:
# tools/depends/configure.ac picks build-tools with `sort -V | tail -n 1`, so a
# root shared with the master target would silently hand this build the wrong
# ones. There is only one target in this image, but the paths stay explicit.
ENV NDK_SDK=/opt/android-sdk-omega
ENV NDK_VERSION=21.4.7075529
ENV NDK_PATH=/opt/android-sdk-omega/ndk/21.4.7075529

# cmdline-tools;latest is not optional. configure.ac requires an sdkmanager
# inside the SDK root it is given, and omega/build-kodi.sh checks for it up
# front rather than failing halfway through ./configure.
#
# The chown belongs in this layer and not a later one. Changing ownership in a
# separate RUN makes the layer a full copy of every file it touches, so a
# standalone `chown -R` over the SDK put roughly four gigabytes into the image
# twice, once owned by root and once by builder.
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

# build-kodi.sh signs every buildType with the Android debug keystore and reads
# it from $HOME, with no way to point it elsewhere. Nothing creates that file
# in a container, so make it here with the well-known values the script
# expects. Self-signed, for sideloading; it is not a secret and its passwords
# are published in Android's own documentation.
ENV HOME=/home/builder
RUN mkdir -p "$HOME/.android" \
 && keytool -genkeypair -v -keystore "$HOME/.android/debug.keystore" \
      -storepass android -keypass android -alias androiddebugkey \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US" >/dev/null \
 && chown -R 1000:1000 "$HOME"

# Everything large and disposable goes here, on whatever volume the caller
# mounts. Deliberately not under $HOME, which holds the baked keystore and
# would be shadowed by a mount.
ENV TARBALLS=/mnt/buildram/tarballs
WORKDIR /mnt/buildram

COPY build-apk.sh /usr/local/bin/build-apk
RUN chmod 0755 /usr/local/bin/build-apk

# Everything from here runs unprivileged. Nothing at run time needs root: the
# packages were installed above, and a build is git, rsync, make, cmake and
# gradle. The volume mounted at WORKDIR needs to be writable by this uid, which
# is the caller's job (fsGroup: 1000).
USER 1000:1000

ENTRYPOINT ["/usr/local/bin/build-apk"]
