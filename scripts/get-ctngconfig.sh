#!/usr/bin/env bash
# Download or build ctngconfig, the Rust-based kconfig replacement.
# Creates symlinks (conf, mconf, nconf -> ctngconfig) for drop-in compat.

set -euo pipefail

CTNGCONFIG_VERSION="v0.1.14"
# ^^ Bump this when upgrading the pinned ctngconfig version.
CTNGCONFIG_REPO="bhundven/ctngconfig"
CTNGCONFIG_BASE_URL="https://github.com/${CTNGCONFIG_REPO}/releases/download"

usage() {
    cat <<'USAGE_EOF'
Usage: get-ctngconfig.sh [OPTIONS]

Download or build ctngconfig and install it into a destination directory.

Options:
  --version=TAG       Version tag to download/build (default: pinned version)
                      Use "latest" to fetch the most recent GitHub release.
  --dest=DIR          Destination directory (required)
  --source-only       Always build from source with cargo; skip binary download.
  --source-dir=PATH   Dev mode: build from a local source checkout.
                      If PATH exists with Cargo.toml, build from it directly.
                      If PATH does not exist, clone the repo there first.
                      Rebuilds only when source is newer than the binary.
  --force             Force re-download/rebuild even if already present.
  --wget=PATH         Path to wget binary
  --curl=PATH         Path to curl binary
  --help              Show this help

Acquisition order (unless --source-only or --source-dir is given):
  1. gh CLI (GitHub CLI) authenticated release download
  2. curl/wget direct download (public releases only)
  3. Build from source with cargo (always tried as fallback)

With --source-only, only the cargo source build is attempted.
With --source-dir, the local checkout is always used (overrides all other modes).
USAGE_EOF
    exit "${1:-0}"
}

msg() {
    echo "get-ctngconfig: $*" >&2
}

err() {
    echo "get-ctngconfig: ERROR: $*" >&2
    exit 1
}

detect_target() {
    local os arch

    os="$(uname -s)"
    arch="$(uname -m)"

    case "${os}" in
        Linux)  os="unknown-linux-gnu" ;;
        Darwin) os="apple-darwin" ;;
        *)      return 1 ;;
    esac

    case "${arch}" in
        x86_64)         arch="x86_64" ;;
        aarch64|arm64)  arch="aarch64" ;;
        *)              return 1 ;;
    esac

    echo "${arch}-${os}"
}

resolve_latest_version() {
    if command -v gh >/dev/null 2>&1; then
        local tag
        tag="$(gh release view --repo "${CTNGCONFIG_REPO}" --json tagName --jq '.tagName' 2>/dev/null)" || true
        if [ -n "${tag}" ]; then
            echo "${tag}"
            return 0
        fi
    fi

    if [ -n "${CURL}" ]; then
        local url="https://api.github.com/repos/${CTNGCONFIG_REPO}/releases/latest"
        local tag
        tag="$("${CURL}" -fsSL "${url}" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')" || true
        if [ -n "${tag}" ]; then
            echo "${tag}"
            return 0
        fi
    fi

    err "cannot resolve 'latest' version: install gh CLI or ensure curl can reach the GitHub API"
}

download_with_wget() {
    local url="$1" dest="$2"
    "${WGET}" -q -O "${dest}" "${url}" 2>/dev/null
}

download_with_curl() {
    local url="$1" dest="$2"
    "${CURL}" -fsSL -o "${dest}" "${url}" 2>/dev/null
}

download() {
    local url="$1" dest="$2"

    if [ -n "${CURL}" ]; then
        download_with_curl "${url}" "${dest}" && return 0
    fi
    if [ -n "${WGET}" ]; then
        download_with_wget "${url}" "${dest}" && return 0
    fi
    return 1
}

verify_checksum() {
    local file="$1" expected_hash="$2"
    local actual_hash

    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash="$(sha256sum "${file}" | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash="$(shasum -a 256 "${file}" | cut -d' ' -f1)"
    else
        msg "WARNING: no sha256sum or shasum found, skipping checksum verification"
        return 0
    fi

    if [ "${actual_hash}" != "${expected_hash}" ]; then
        err "checksum mismatch for ${file}: expected ${expected_hash}, got ${actual_hash}"
    fi
    msg "checksum verified"
}

try_gh_download() {
    local version="$1" dest_dir="$2"
    local target asset_name tmpdir

    if ! command -v gh >/dev/null 2>&1; then
        msg "gh CLI not found, skipping"
        return 1
    fi

    target="$(detect_target)" || { msg "unsupported platform for pre-built binary"; return 1; }
    asset_name="ctngconfig-${target}.tar.gz"

    msg "detected platform: ${target}"
    msg "downloading via gh CLI: ${asset_name} (${version})"

    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    if ! gh release download "${version}" \
        --repo "${CTNGCONFIG_REPO}" \
        --pattern "${asset_name}" \
        --pattern "SHA256SUMS" \
        --dir "${tmpdir}" 2>/dev/null; then
        msg "gh release download failed"
        return 1
    fi

    if [ -f "${tmpdir}/SHA256SUMS" ]; then
        local expected_hash
        expected_hash="$(grep "${asset_name}" "${tmpdir}/SHA256SUMS" | cut -d' ' -f1)"
        if [ -n "${expected_hash}" ]; then
            verify_checksum "${tmpdir}/${asset_name}" "${expected_hash}"
        fi
    fi

    msg "extracting to ${dest_dir}"
    mkdir -p "${dest_dir}"
    tar xzf "${tmpdir}/${asset_name}" -C "${dest_dir}"

    if [ ! -x "${dest_dir}/ctngconfig" ]; then
        err "extraction succeeded but ctngconfig binary not found"
    fi

    return 0
}

try_direct_download() {
    local version="$1" dest_dir="$2"
    local target asset_name asset_url checksums_url
    local expected_hash tmpdir

    if [ -z "${WGET}" ] && [ -z "${CURL}" ]; then
        return 1
    fi

    target="$(detect_target)" || { msg "unsupported platform for pre-built binary"; return 1; }
    asset_name="ctngconfig-${target}.tar.gz"
    asset_url="${CTNGCONFIG_BASE_URL}/${version}/${asset_name}"
    checksums_url="${CTNGCONFIG_BASE_URL}/${version}/SHA256SUMS"

    msg "detected platform: ${target}"
    msg "downloading ${asset_url}"

    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    if ! download "${asset_url}" "${tmpdir}/${asset_name}"; then
        msg "direct download failed (repo may be private; try installing gh CLI)"
        return 1
    fi

    if download "${checksums_url}" "${tmpdir}/SHA256SUMS"; then
        expected_hash="$(grep "${asset_name}" "${tmpdir}/SHA256SUMS" | cut -d' ' -f1)"
        if [ -n "${expected_hash}" ]; then
            verify_checksum "${tmpdir}/${asset_name}" "${expected_hash}"
        else
            msg "WARNING: asset not found in SHA256SUMS, skipping verification"
        fi
    else
        msg "WARNING: could not download SHA256SUMS, skipping verification"
    fi

    msg "extracting to ${dest_dir}"
    mkdir -p "${dest_dir}"
    tar xzf "${tmpdir}/${asset_name}" -C "${dest_dir}"

    if [ ! -x "${dest_dir}/ctngconfig" ]; then
        err "extraction succeeded but ctngconfig binary not found"
    fi

    return 0
}

try_cargo_build() {
    local version="$1" dest_dir="$2"

    if ! command -v cargo >/dev/null 2>&1; then
        msg "cargo not found in PATH"
        return 1
    fi

    msg "building ctngconfig from source (${version}) with cargo..."
    mkdir -p "${dest_dir}"

    if ! cargo install \
        --git "https://github.com/${CTNGCONFIG_REPO}.git" \
        --tag "${version}" \
        --root "${dest_dir}" \
        --force 2>&1 | while IFS= read -r line; do msg "cargo: ${line}"; done
    then
        msg "cargo install command failed"
        return 1
    fi

    if [ ! -x "${dest_dir}/bin/ctngconfig" ]; then
        msg "cargo build did not produce ctngconfig binary"
        return 1
    fi

    mv "${dest_dir}/bin/ctngconfig" "${dest_dir}/ctngconfig"
    rmdir "${dest_dir}/bin" 2>/dev/null || true
    rm -f "${dest_dir}/.crates.toml" "${dest_dir}/.crates2.json"
    return 0
}

try_local_build() {
    local src_dir="$1" dest_dir="$2" version="$3"
    local cargo_bin="${src_dir}/target/release/ctngconfig"

    if ! command -v cargo >/dev/null 2>&1; then
        err "cargo not found in PATH (required for --source-dir dev builds)"
    fi

    if [ ! -d "${src_dir}" ]; then
        msg "source directory does not exist, cloning into ${src_dir}"
        if command -v git >/dev/null 2>&1; then
            git clone "https://github.com/${CTNGCONFIG_REPO}.git" "${src_dir}"
            if [ -n "${version}" ] && [ "${version}" != "latest" ]; then
                git -C "${src_dir}" checkout "${version}" 2>/dev/null || \
                    msg "WARNING: could not checkout ${version}, using default branch"
            fi
        else
            err "git not found; cannot clone source into ${src_dir}"
        fi
    fi

    if [ ! -f "${src_dir}/Cargo.toml" ]; then
        err "no Cargo.toml found in ${src_dir}; not a valid ctngconfig source tree"
    fi

    # Only rebuild if source files are newer than the existing binary
    if [ "${FORCE}" = "no" ] && [ -x "${dest_dir}/ctngconfig" ]; then
        local newest_src
        newest_src="$(find "${src_dir}/src" "${src_dir}/Cargo.toml" "${src_dir}/Cargo.lock" \
            -newer "${dest_dir}/ctngconfig" 2>/dev/null | head -1)"
        if [ -z "${newest_src}" ]; then
            msg "local build is up-to-date (no source changes since last build)"
            return 0
        fi
        msg "source changes detected, rebuilding..."
    fi

    msg "building ctngconfig from local source: ${src_dir}"
    if ! cargo build --release --manifest-path "${src_dir}/Cargo.toml" \
        2>&1 | while IFS= read -r line; do msg "cargo: ${line}"; done
    then
        err "cargo build failed in ${src_dir}"
    fi

    if [ ! -x "${cargo_bin}" ]; then
        err "cargo build succeeded but ${cargo_bin} not found"
    fi

    mkdir -p "${dest_dir}"
    cp "${cargo_bin}" "${dest_dir}/ctngconfig"
    msg "installed dev build from ${src_dir}"
    return 0
}

create_symlinks() {
    local dest_dir="$1"

    msg "creating symlinks in ${dest_dir}"
    cd "${dest_dir}"
    for name in conf mconf nconf; do
        ln -sf ctngconfig "${name}"
    done
}

# -- Main --

VERSION="${CTNGCONFIG_VERSION}"
DEST=""
WGET=""
CURL=""
SOURCE_ONLY=no
SOURCE_DIR=""
FORCE=no

for arg in "$@"; do
    case "${arg}" in
        --version=*)    VERSION="${arg#*=}" ;;
        --dest=*)       DEST="${arg#*=}" ;;
        --wget=*)       WGET="${arg#*=}" ;;
        --curl=*)       CURL="${arg#*=}" ;;
        --source-only)  SOURCE_ONLY=yes ;;
        --source-dir=*) SOURCE_DIR="${arg#*=}" ;;
        --force)        FORCE=yes ;;
        --help|-h)      usage 0 ;;
        *)              err "unknown option: ${arg}" ;;
    esac
done

if [ -z "${DEST}" ]; then
    err "--dest=DIR is required"
fi

# Auto-detect download tools if not specified
if [ -z "${WGET}" ]; then
    WGET="$(command -v wget 2>/dev/null || true)"
fi
if [ -z "${CURL}" ]; then
    CURL="$(command -v curl 2>/dev/null || true)"
fi

# Resolve "latest" to an actual tag before doing anything else
if [ "${VERSION}" = "latest" ]; then
    msg "resolving latest release version..."
    VERSION="$(resolve_latest_version)"
    msg "resolved to: ${VERSION}"
fi

DEST="$(mkdir -p "${DEST}" && cd "${DEST}" && pwd)"

msg "version: ${VERSION}"
msg "destination: ${DEST}"
if [ -n "${SOURCE_DIR}" ]; then
    msg "dev mode: source-dir=${SOURCE_DIR}"
else
    msg "source-only: ${SOURCE_ONLY}"
fi

# Dev mode (--source-dir) overrides all other acquisition strategies.
# The incremental rebuild check is inside try_local_build.
if [ -n "${SOURCE_DIR}" ]; then
    try_local_build "${SOURCE_DIR}" "${DEST}" "${VERSION}"
    create_symlinks "${DEST}"
    msg "done: ${DEST}/ctngconfig"
    exit 0
fi

# Skip re-acquisition if the correct version is already present (unless --force)
if [ "${FORCE}" = "no" ] && [ -x "${DEST}/ctngconfig" ]; then
    existing_ver="$("${DEST}/ctngconfig" --version 2>/dev/null | head -1 || true)"
    if echo "${existing_ver}" | grep -qF "${VERSION#v}"; then
        msg "ctngconfig ${VERSION} already present at ${DEST}/ctngconfig"
        create_symlinks "${DEST}"
        exit 0
    fi
fi

if [ "${SOURCE_ONLY}" = "yes" ]; then
    if try_cargo_build "${VERSION}" "${DEST}"; then
        msg "built from source"
    else
        err "source build failed. Ensure cargo is installed (https://rustup.rs)."
    fi
else
    if try_gh_download "${VERSION}" "${DEST}"; then
        msg "installed pre-built binary (via gh CLI)"
    elif try_direct_download "${VERSION}" "${DEST}"; then
        msg "installed pre-built binary (via direct download)"
    elif try_cargo_build "${VERSION}" "${DEST}"; then
        msg "built from source (binary download unavailable)"
    else
        err "failed to acquire ctngconfig ${VERSION}. Install gh CLI, cargo (https://rustup.rs), or download manually."
    fi
fi

create_symlinks "${DEST}"
msg "done: ${DEST}/ctngconfig"
