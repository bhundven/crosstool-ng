#!/usr/bin/env bash
#
# Apply the .config tweaks shared by the crosstool-NG CI source-prep and
# toolchain-build jobs. Operates on the file given as $1 (default: ./.config).
#
# Job-specific tweaks (CT_COMP_TOOLS_*, CT_DOWNLOAD_WGET_OPTIONS,
# CT_GLIBC_ENABLE_DEBUG, ...) are intentionally left in the workflows.

set -euo pipefail

config="${1:-.config}"

# Don't render the progress bar into non-interactive CI logs.
sed -i -e '/CT_LOG_PROGRESS_BAR/s/y$/n/' "${config}"

# Keep downloaded tarballs and the install prefix inside the work tree
# (CT_TOP_DIR) instead of $HOME so they persist across CI steps and artifacts.
sed -i -e '/CT_LOCAL_TARBALLS_DIR/s/HOME/CT_TOP_DIR/' "${config}"
sed -i -e '/CT_PREFIX_DIR/s/HOME/CT_TOP_DIR/' "${config}"
