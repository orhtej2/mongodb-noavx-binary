# MongoDB Debian packages

This repository builds MongoDB Community Debian packages for Bookworm and Trixie on native Ubuntu 22.04 amd64 and arm64 runners. Each build uses the Debian control/rules files from the exact MongoDB source tag being compiled.

The daily workflow runs at 20:00 UTC. It finds the newest stable MongoDB tag in each major series starting at 7 and dispatches a build if this repository has not published that version. All upstream-generated `.deb` packages are attached to a versioned GitHub Release.

To build locally, install prerequisites and run the same Bash entry point used by Actions:

```bash
sudo bash scripts/mongodb-debs.sh install-deps
bash scripts/mongodb-debs.sh build 8.3.11
```

That builds both Debian suites for the local native architecture. To build one suite, append `bookworm` or `trixie`; for example, `bash scripts/mongodb-debs.sh build 8.3.11 bookworm`. The version must match a stable upstream tag named `r<version>`.

Source archives are cached by version in `~/.cache/mongodb-baseline/sources`, so retries and the second suite reuse the download. Override the location with `MONGODB_SOURCE_CACHE=/path/to/cache`.

MongoDB 7.x uses the SCons/MozJS no-AVX patch. MongoDB 8.x and later use the Bazel toolchain patch, which changes `-march=sandybridge` to `-march=x86-64-v2`; amd64 packages are smoke-tested under QEMU using a Westmere CPU model without AVX. Package metadata and lifecycle scripts come from the selected MongoDB tag.

MongoDB 7.x and 8.x upstream build documentation supports arm64, not 32-bit armhf. This workflow therefore publishes amd64 and arm64 packages; it does not claim armhf support.