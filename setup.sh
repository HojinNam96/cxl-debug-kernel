#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Fetch Linux v7.3 (torvalds/linux; --stable for the v7.3.x stable tag), apply the CXL/DAX debug patch and produce a .config
# (base config + config/cxl-debug.config). Does not build unless --build.
set -euo pipefail

VERSION=v7.3
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$HERE/linux-${VERSION#v}
BASE=/boot/config-$(uname -r)
LOCALVER=-cxldbg
BUILD=0
REPO=https://github.com/torvalds/linux.git
STABLE_REPO=https://github.com/gregkh/linux.git

usage() {
	cat <<EOF
usage: $0 [--stable TAG] [--dir DIR] [--base-config FILE] [--localversion STR] [--build]
  --stable TAG        use a stable point release from gregkh/linux instead (e.g. v7.3.5)
  --dir DIR           kernel tree location (default: $DIR)
  --base-config FILE  starting config (default: $BASE, i.e. the running distro kernel)
  --localversion STR  CONFIG_LOCALVERSION (default: $LOCALVER)
  --build             also run 'make -j\$(nproc)' at the end
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--stable) VERSION=$2; REPO=$STABLE_REPO; DIR=$HERE/linux-${VERSION#v}; shift 2 ;;
	--dir) DIR=$2; shift 2 ;;
	--base-config) BASE=$2; shift 2 ;;
	--localversion) LOCALVER=$2; shift 2 ;;
	--build) BUILD=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ -r "$BASE" ] || { echo "base config not readable: $BASE (use --base-config)" >&2; exit 1; }

if [ ! -d "$DIR/.git" ]; then
	echo ">> cloning $VERSION into $DIR (shallow)"
	git clone --depth 1 --branch "$VERSION" "$REPO" "$DIR"
fi

cd "$DIR"
if git apply --check "$HERE/patches/0001-cxl-dax-debug-output.patch" 2>/dev/null; then
	echo ">> applying patches/0001-cxl-dax-debug-output.patch"
	git apply "$HERE/patches/0001-cxl-dax-debug-output.patch"
elif git apply --reverse --check "$HERE/patches/0001-cxl-dax-debug-output.patch" 2>/dev/null; then
	echo ">> patch already applied"
else
	echo "patch does not apply cleanly to $DIR" >&2; exit 1
fi

echo ">> config: $BASE + config/cxl-debug.config"
cp "$BASE" .config
scripts/kconfig/merge_config.sh -m .config "$HERE/config/cxl-debug.config" >/dev/null
# distro configs reference signing certs that are not in the tree
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
	--set-str LOCALVERSION "$LOCALVER"
make olddefconfig >/dev/null

dropped=0
while read -r l; do
	if ! grep -qx "$l" .config; then
		echo "DROPPED: $l -> $(grep "^${l%%=*}=" .config || echo 'not set')" >&2
		dropped=1
	fi
done < <(grep -E '^CONFIG_' "$HERE/config/cxl-debug.config")
if [ "$dropped" = 1 ]; then
	echo "some fragment options did not survive olddefconfig (missing dependency in the base config); fix before building" >&2
	exit 1
fi
echo ">> all fragment options present in .config"

if [ "$BUILD" = 1 ]; then
	make -j"$(nproc)"
	echo ">> built. install with: sudo make modules_install && sudo make install"
else
	cat <<EOF
>> ready. next:
   cd $DIR
   make -j\$(nproc)            # or: make -j\$(nproc) bindeb-pkg
   sudo make modules_install && sudo make install
   add the parameters from cmdline.txt to the kernel command line, then reboot
EOF
fi
