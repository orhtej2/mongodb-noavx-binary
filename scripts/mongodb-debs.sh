#!/usr/bin/env bash
set -Eeuo pipefail
exec </dev/null

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES=(bookworm trixie)
ARCHITECTURES=(amd64 arm64)
BUILD_JOBS="${BUILD_JOBS:-2}"
WORK_DIR=""
export CI=1
export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export PIP_NO_INPUT=1

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

log() {
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/mongodb-debs.sh install-deps
  bash scripts/mongodb-debs.sh build VERSION [bookworm|trixie [amd64|arm64]]
  bash scripts/mongodb-debs.sh publish VERSION [ASSET_DIR]

With only VERSION, build both Debian suites for the native architecture.
EOF
}

validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || (( 10#${BASH_REMATCH[1]} < 7 )); then
        echo "Expected a stable MongoDB version >= 7 in x.y.z form; got: $version" >&2
        exit 2
    fi
}

native_architecture() {
    case "$(dpkg --print-architecture)" in
        amd64) printf 'amd64\n' ;;
        arm64) printf 'arm64\n' ;;
        armhf)
            echo "MongoDB upstream source supports arm64, not 32-bit armhf" >&2
            return 1
            ;;
        *)
            echo "Unsupported native architecture: $(dpkg --print-architecture)" >&2
            return 1
            ;;
    esac
}

install_deps() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Run dependency installation with sudo: sudo bash scripts/mongodb-debs.sh install-deps" >&2
        exit 1
    fi

    log "Installing native build prerequisites"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential ca-certificates curl dpkg-dev fakeroot git lld \
        patch pkg-config debhelper libcurl4-openssl-dev liblzma-dev libssl-dev \
        libzstd-dev python3 python3-dev python3-pip python3-venv qemu-user
}

apply_bazel_no_avx() {
    local config="$1"
    local original='-march=sandybridge", "-mtune=generic", "-mprefer-vector-width=128'
    local replacement='-march=x86-64-v2", "-mtune=generic'

    if grep -Fq -- "$replacement" "$config"; then
        return
    fi
    if [[ "$(grep -Fc -- "$original" "$config")" -ne 1 ]]; then
        echo "Expected one MongoDB Bazel sandybridge flag in $config; refusing an unverified patch" >&2
        return 1
    fi
    sed -i "s|$original|$replacement|" "$config"
    grep -Fq -- "$replacement" "$config"
}

prepare_mongo_bazel_toolchain() {
    local source_dir="$1"
    local distro_utils="$source_dir/bazel/utils.bzl"
    local distro_id
    local distro_version

    . /etc/os-release
    distro_id="$ID"
    distro_version="$VERSION_ID"
    case "$distro_id:$distro_version" in
        ubuntu:18.*|ubuntu:20.*|ubuntu:22.*|ubuntu:24.*|debian:10|debian:12) return 0 ;;
        debian:13)
            if grep -Fq '"Debian GNU/Linux 13": "ubuntu22"' "$distro_utils"; then
                return 0
            fi
            if ! grep -Fq '"Debian GNU/Linux 12": "debian12",' "$distro_utils"; then
                echo "Cannot map Debian 13 to MongoDB's supported Ubuntu 22 toolchain in $distro_utils" >&2
                return 1
            fi
            sed -i '/"Debian GNU\/Linux 12": "debian12",/a\        "Debian GNU/Linux 13": "ubuntu22",' "$distro_utils"
            log "Using MongoDB's Ubuntu 22.04 hermetic toolchain for local Debian 13"
            return 0
            ;;
        *) return 1 ;;
    esac
}

build_one() {
    local version="$1"
    local suite="$2"
    local arch="$3"
    local expected_arch="${4:-$arch}"
    local major="${version%%.*}"
    local actual_arch
    local source_dir
    local bazel_path
    local server_package
    local router_package
    local output_dir="$ROOT_DIR/dist/$suite/$arch/$version"
    local flags
    local package
    local debs=()

    if [[ ! " ${SUITES[*]} " == *" $suite "* ]]; then
        echo "Unsupported Debian suite: $suite" >&2
        exit 2
    fi
    if [[ ! " ${ARCHITECTURES[*]} " == *" $arch "* ]]; then
        echo "Unsupported package architecture: $arch" >&2
        exit 2
    fi
    actual_arch="$(native_architecture)"
    if [[ "$actual_arch" != "$expected_arch" || "$actual_arch" != "$arch" ]]; then
        echo "Runner architecture mismatch: expected $expected_arch/$arch, got $actual_arch" >&2
        exit 1
    fi
    for tool in curl tar patch python3 dpkg-buildpackage; do
        command -v "$tool" >/dev/null || { echo "Missing build prerequisite: $tool (run install-deps)" >&2; exit 1; }
    done

    WORK_DIR="$(mktemp -d)"
    source_dir="$WORK_DIR/mongo"
    mkdir -p "$source_dir"
    log "Downloading MongoDB $version source for $suite/$arch"
    curl -fsSL --retry 3 \
        "https://github.com/mongodb/mongo/archive/refs/tags/r${version}.tar.gz" \
        -o "$WORK_DIR/mongo.tar.gz"
    tar -xzf "$WORK_DIR/mongo.tar.gz" --strip-components=1 -C "$source_dir"

    log "Installing MongoDB Python build requirements"
    python3 -m venv "$WORK_DIR/venv"
    if [[ -f "$source_dir/etc/pip/compile-requirements.txt" ]]; then
        "$WORK_DIR/venv/bin/pip" install --no-input --disable-pip-version-check --upgrade pip
        "$WORK_DIR/venv/bin/pip" install --no-input --disable-pip-version-check requirements_parser
        "$WORK_DIR/venv/bin/pip" install --no-input --disable-pip-version-check -r "$source_dir/etc/pip/compile-requirements.txt"
    else
        log "No legacy SCons requirements file in this tag; continuing with its Bazel setup"
    fi

    if [[ "$major" == "7" ]]; then
        log "Applying MongoDB 7.x no-AVX patch"
        (cd "$source_dir" && patch --batch --forward -p1 < "$ROOT_DIR/patches/mongodb-7-no-avx.patch")
        flags='-O3 -march=x86-64 -mtune=generic -mno-avx -mno-avx2 -mno-fma'
        if [[ "$arch" == "arm64" ]]; then
            flags='-O3 -march=armv8-a -mtune=generic'
        fi
        log "Building MongoDB $version with SCons"
        (cd "$source_dir" && "$WORK_DIR/venv/bin/python" buildscripts/scons.py \
            install-mongod install-mongos MONGO_VERSION="$version" \
            --release --disable-warnings-as-errors -j "$BUILD_JOBS" \
            CCFLAGS="$flags" CXXFLAGS="$flags")
        install -D -m 0755 "$source_dir/build/install/bin/mongod" "$source_dir/bin/mongod"
        install -D -m 0755 "$source_dir/build/install/bin/mongos" "$source_dir/bin/mongos"
    else
        log "Installing MongoDB $version Bazel"
        (cd "$source_dir" && "$WORK_DIR/venv/bin/python" buildscripts/install_bazel.py)
        export PATH="$HOME/.local/bin:$PATH"
        local use_mongo_hermetic_toolchain=false
        if prepare_mongo_bazel_toolchain "$source_dir"; then
            use_mongo_hermetic_toolchain=true
        fi
        if [[ "$arch" == "amd64" ]]; then
            log "Applying generic x86-64 Bazel toolchain target"
            apply_bazel_no_avx "$source_dir/bazel/toolchains/cc/mongo_linux/mongo_linux_cc_toolchain_config.bzl"
        fi
        bazel_path="$HOME/.local/bin/bazel"
        if [[ ! -x "$bazel_path" ]]; then
            bazel_path="$(command -v bazel || true)"
        fi
        [[ -n "$bazel_path" ]] || { echo "MongoDB Bazel installer did not provide bazel" >&2; exit 1; }
        local bazel_env=()
        local bazel_flags=(--config=opt --jobs="$BUILD_JOBS" --disable_warnings_as_errors=True)
        local ca_bundle="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
        if [[ -r "$ca_bundle" ]]; then
            bazel_flags+=(
                "--action_env=SSL_CERT_FILE=$ca_bundle"
                "--action_env=REQUESTS_CA_BUNDLE=$ca_bundle"
                "--action_env=AWS_CA_BUNDLE=$ca_bundle"
                "--repo_env=SSL_CERT_FILE=$ca_bundle"
                "--repo_env=REQUESTS_CA_BUNDLE=$ca_bundle"
                "--repo_env=AWS_CA_BUNDLE=$ca_bundle"
            )
        fi
        if [[ "$use_mongo_hermetic_toolchain" == false ]]; then
            log "No MongoDB hermetic toolchain for this distro; using the native compiler"
            bazel_env+=(USE_NATIVE_TOOLCHAIN=1)
            bazel_flags+=(--repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=0
                --copt=-D_GNU_SOURCE --cxxopt=-D_GNU_SOURCE)
            if [[ "$arch" == "amd64" ]]; then
                bazel_flags+=(--copt=-march=x86-64-v2 --cxxopt=-march=x86-64-v2
                    --copt=-mtune=generic --cxxopt=-mtune=generic
                    --copt=-mno-avx --cxxopt=-mno-avx
                    --copt=-mno-avx2 --cxxopt=-mno-avx2
                    --copt=-mno-fma --cxxopt=-mno-fma)
            else
                bazel_flags+=(--copt=-march=armv8-a --cxxopt=-march=armv8-a
                    --copt=-mtune=generic --cxxopt=-mtune=generic)
            fi
        fi
        log "Building MongoDB $version with Bazel"
        (cd "$source_dir" && env "${bazel_env[@]}" "$bazel_path" build \
            "${bazel_flags[@]}" install-dist)
        install -D -m 0755 "$source_dir/bazel-bin/install/bin/mongod" "$source_dir/bin/mongod"
        install -D -m 0755 "$source_dir/bazel-bin/install/bin/mongos" "$source_dir/bin/mongos"
    fi

    install -D -m 0755 "$source_dir/src/mongo/installer/compass/install_compass" \
        "$source_dir/bin/install_compass"

    cp "$source_dir/debian/mongodb-org.control" "$source_dir/debian/control"
    cp "$source_dir/debian/mongodb-org.rules" "$source_dir/debian/rules"
    chmod 0755 "$source_dir/debian/rules"
    printf 'mongodb-org (%s-1~%s) %s; urgency=medium\n\n  * Build MongoDB %s for Debian %s.\n\n -- MongoDB Baseline Builds <mongodb-baseline@example.invalid>  %s\n' \
        "$version" "$suite" "$suite" "$version" "$suite" "$(date -R)" \
        > "$source_dir/debian/changelog"

    log "Building upstream Debian packages for $suite/$arch"
    (cd "$source_dir" && DEB_BUILD_OPTIONS="parallel=$BUILD_JOBS" dpkg-buildpackage -b -us -uc -rfakeroot)

    mkdir -p "$output_dir"
    while IFS= read -r -d '' package; do
        debs+=("$package")
        cp "$package" "$output_dir/"
    done < <(find "$WORK_DIR" -maxdepth 1 -type f -name '*.deb' -print0)
    if (( ${#debs[@]} == 0 )); then
        echo "Upstream Debian rules produced no .deb files" >&2
        exit 1
    fi

    server_package="$(find "$output_dir" -maxdepth 1 -type f -name "mongodb-org-server_*_${arch}.deb" -print -quit)"
    router_package="$(find "$output_dir" -maxdepth 1 -type f -name "mongodb-org-mongos_*_${arch}.deb" -print -quit)"
    [[ -n "$server_package" && -n "$router_package" ]] || {
        echo "Upstream rules did not produce both server and mongos packages" >&2
        exit 1
    }
    mkdir -p "$WORK_DIR/smoke"
    dpkg-deb -x "$server_package" "$WORK_DIR/smoke"
    dpkg-deb -x "$router_package" "$WORK_DIR/smoke"
    log "Smoke-testing mongod and mongos for $suite/$arch"
    if [[ "$arch" == "amd64" ]]; then
        qemu-x86_64 -cpu Westmere -L / "$WORK_DIR/smoke/usr/bin/mongod" --version
        qemu-x86_64 -cpu Westmere -L / "$WORK_DIR/smoke/usr/bin/mongos" --version
    else
        "$WORK_DIR/smoke/usr/bin/mongod" --version
        "$WORK_DIR/smoke/usr/bin/mongos" --version
    fi

    printf 'Built %d upstream DEB packages for MongoDB %s (%s/%s)\n' \
        "${#debs[@]}" "$version" "$suite" "$arch"
    cleanup
    WORK_DIR=""
}

build() {
    local version="$1"
    local suite="${2:-}"
    local arch="${3:-$(native_architecture)}"
    local item
    validate_version "$version"

    if [[ -n "$suite" ]]; then
        build_one "$version" "$suite" "$arch" "$arch"
        return
    fi
    for item in "${SUITES[@]}"; do
        build_one "$version" "$item" "$arch" "$arch"
    done
}

publish() {
    local version="$1"
    local asset_dir="${2:-$ROOT_DIR/dist}"
    local release_tag="mongodb-noavx-$version"
    local target="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
    local suite
    local arch
    local package
    local assets=()
    validate_version "$version"
    command -v gh >/dev/null || { echo "GitHub CLI (gh) is required to publish" >&2; exit 1; }

    for suite in "${SUITES[@]}"; do
        for arch in "${ARCHITECTURES[@]}"; do
            if ! find "$asset_dir/$suite/$arch/$version" -maxdepth 1 -type f -name 'mongodb-org-server_*.deb' -print -quit | grep -q .; then
                echo "Missing upstream mongodb-org-server package for $suite/$arch under $asset_dir" >&2
                exit 1
            fi
            while IFS= read -r -d '' package; do
                assets+=("$package")
            done < <(find "$asset_dir/$suite/$arch/$version" -maxdepth 1 -type f -name '*.deb' -print0)
        done
    done
    if (( ${#assets[@]} == 0 )); then
        echo "No Debian packages found under $asset_dir" >&2
        exit 1
    fi

    if gh release view "$release_tag" >/dev/null 2>&1; then
        gh release upload "$release_tag" "${assets[@]}" --clobber
    else
        gh release create "$release_tag" "${assets[@]}" \
            --target "$target" \
            --title "MongoDB $version without AVX" \
            --notes "MongoDB upstream Debian packages for Bookworm and Trixie on amd64 and arm64. The amd64 build targets x86-64-v2 and does not require AVX."
    fi
}

main() {
    local command="${1:-}"
    shift || true
    case "$command" in
        install-deps)
            [[ "$#" -eq 0 ]] || { usage >&2; exit 2; }
            install_deps
            ;;
        build)
            [[ "$#" -ge 1 && "$#" -le 3 ]] || { usage >&2; exit 2; }
            build "$@"
            ;;
        publish)
            [[ "$#" -ge 1 && "$#" -le 2 ]] || { usage >&2; exit 2; }
            publish "$@"
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"