# TODO

## The Android command line tools URL will 404 eventually

`omega/builder/Dockerfile` downloads

    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip

Google publishes these with a build number in the filename and removes old ones
after a while. When that happens the image stops building, and it will happen on
the day someone needs a build rather than on a quiet afternoon: this pipeline
runs every few weeks at most, so nothing exercises it in between.

Everything else here is better anchored. The NDK, platform and build-tools come
through `sdkmanager`, which resolves them from Google's own repository index, and
Kodi is pinned to a tag.

Options, none of them investigated:

- Mirror the zip somewhere of ours and pull it from there.
- Fetch whatever `commandlinetools-linux-*_latest.zip` currently is, and accept
  that the toolchain version then drifts between image builds.
- Find out whether `sdkmanager` can bootstrap itself from a version that ships in
  a package, so the zip is not needed at all.

The first is the least clever and probably the right one.
