# TODO

## The Android command line tools URL will 404 eventually

`omega/builder/Dockerfile` downloads

    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip

Google puts a build number in the filename and removes old ones. Nothing else
here has this problem: the NDK, platform and build-tools come through
`sdkmanager`, and Kodi is pinned to a tag. Since this pipeline runs every few
weeks at most, it will break on the day someone needs a build.

Options, none investigated:

- Mirror the zip ourselves and pull it from there.
- Fetch whatever `commandlinetools-linux-*_latest.zip` currently is, accepting
  that the toolchain drifts between image builds.
- Check whether `sdkmanager` can bootstrap itself from a packaged version, so
  the zip is not needed.

The first is probably right.
