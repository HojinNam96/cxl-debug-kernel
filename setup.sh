#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Prepare a Linux v7.3 tree with the CXL/DAX debug patch and a .config
# (base config + config/cxl-debug.config), then optionally build it.
#
# OFFLINE: needs no network when the kernel source is here:
#   - ./linux-7.3 (a clone or archive of this repository: committed, already patched), or
#   - linux-7.3.tar.xz next to this kit or one directory up (the offline bundle), or --tarball FILE.
# Only with neither does it try 'git clone' (needs internet).
set -euo pipefail

VERSION=v7.3
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=""
BASE=""
TARBALL=""
LOCALVER=-cxldbg
BUILD=0
KEEP_DEBUG_INFO=0
JOBS=$(nproc 2>/dev/null || echo 4)
REPO=https://github.com/torvalds/linux.git
STABLE_REPO=https://github.com/gregkh/linux.git
PATCH=$HERE/patches/0001-cxl-dax-debug-output.patch

usage() {
	cat <<EOF
usage: $0 [--tarball FILE] [--dir DIR] [--base-config FILE|defconfig] [--localversion STR]
          [--keep-debug-info] [--jobs N] [--build] [--stable TAG]
  --tarball FILE      kernel source tarball (default: linux-${VERSION#v}.tar.xz next to this kit, if present)
  --dir DIR           kernel tree location (default: $HERE/linux-${VERSION#v})
  --base-config FILE  starting config. Default: /boot/config-\$(uname -r), else /proc/config.gz.
                      Building for another machine: copy ITS /boot/config-<ver> here and pass it.
                      'defconfig' = plain x86_64 defconfig (only for test builds).
  --localversion STR  CONFIG_LOCALVERSION (default: $LOCALVER -> uname -r = ${VERSION#v}.0$LOCALVER)
  --keep-debug-info   keep the base config's DWARF debug info (default: off; the build is several
                      times faster and smaller, and pahole/libdw are not needed)
  --jobs N            parallel make jobs (default: $JOBS)
  --build             also run make at the end (log: <tree>/build.log)
  --stable TAG        ONLINE only: git clone a stable tag from gregkh/linux (e.g. v7.3.5)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--tarball) TARBALL=$2; shift 2 ;;
	--stable) VERSION=$2; REPO=$STABLE_REPO; shift 2 ;;
	--dir) DIR=$2; shift 2 ;;
	--base-config) BASE=$2; shift 2 ;;
	--localversion) LOCALVER=$2; shift 2 ;;
	--keep-debug-info) KEEP_DEBUG_INFO=1; shift ;;
	--jobs) JOBS=$2; shift 2 ;;
	--build) BUILD=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

say() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
abspath() { case "$1" in ''|/*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }

V=${VERSION#v}
[ -n "$DIR" ] || DIR=$HERE/linux-$V
DIR=$(abspath "$DIR")
TARBALL=$(abspath "$TARBALL")
[ "$BASE" = defconfig ] || BASE=$(abspath "$BASE")
case "$DIR" in *[[:space:]:]*) die "kernel tree path must not contain spaces or ':' (Kbuild refuses): $DIR" ;; esac

# ---------------------------------------------------------------- 1. kernel source
if [ -z "$TARBALL" ]; then
	for c in "$HERE/linux-$V.tar.xz" "$HERE/../linux-$V.tar.xz" "$HERE/linux-$V.tar.gz" "$HERE/../linux-$V.tar.gz"; do
		[ -f "$c" ] && { TARBALL=$(cd "$(dirname "$c")" && pwd)/$(basename "$c"); break; }
	done
fi

if [ -f "$DIR/Makefile" ]; then
	say "using existing kernel tree $DIR"
elif [ -n "$TARBALL" ]; then
	[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"
	sums=$(dirname "$TARBALL")/SHA256SUMS
	if [ -f "$sums" ] && grep -q " $(basename "$TARBALL")\$" "$sums"; then
		say "checking sha256 of $(basename "$TARBALL")"
		(cd "$(dirname "$TARBALL")" && grep " $(basename "$TARBALL")\$" SHA256SUMS | sha256sum -c -) || die "tarball checksum mismatch (corrupted transfer?)"
	fi
	case "$TARBALL" in *.xz) have xz || die "xz is needed to unpack $TARBALL (package xz-utils / xz)" ;; esac
	if [ -d "$DIR" ]; then
		if [ -z "$(ls -A "$DIR")" ]; then rmdir "$DIR"; else die "$DIR exists and is not a kernel tree (no Makefile); remove it or pick another --dir"; fi
	fi
	parent=$(dirname "$DIR")
	mkdir -p "$parent"
	tmp=$parent/.unpack-linux-$V.$$
	trap 'rm -rf "$tmp"' EXIT
	mkdir "$tmp"
	say "unpacking $(basename "$TARBALL") (no network needed; 1-3 min)"
	tar -xf "$TARBALL" -C "$tmp"
	[ -f "$tmp/linux-$V/Makefile" ] || die "tarball did not contain linux-$V/"
	mv "$tmp/linux-$V" "$DIR"          # only a completely unpacked tree ever appears at $DIR
	rm -rf "$tmp"; trap - EXIT
else
	echo ">> no linux-$V.tar.xz next to the kit and no --tarball: trying git clone (needs internet)" >&2
	have git || die "no kernel tarball and no git. Offline: keep cxl-debug-kernel/ next to linux-$V.tar.xz (bundle layout) or pass --tarball FILE."
	git clone --depth 1 --branch "$VERSION" "$REPO" "$DIR" || die "git clone failed. Offline? Use the offline bundle: --tarball /path/linux-$V.tar.xz"
	rm -rf "$DIR/.git"                 # same state as a tarball; otherwise kernelrelease gets '-dirty' after patching
fi

cd "$DIR"
mk=$(sed -n 's/^\(VERSION\|PATCHLEVEL\|SUBLEVEL\) = //p' Makefile | paste -sd.)
say "kernel source version: $mk"

# ---------------------------------------------------------------- 2. debug patch
patched() { grep -q cxl_probe_fail drivers/cxl/pci.c && grep -q -- '-DDEBUG' drivers/cxl/Makefile && grep -q -- '-DDEBUG' drivers/dax/Makefile; }
copy_prepatched() {
	local pp=$HERE/patches/prepatched-v7.3 o n f
	[ -f "$pp/SHA256SUMS" ] || return 1
	while read -r o n f; do
		[ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$o" ] || return 1
	done < "$pp/SHA256SUMS"
	while read -r o n f; do cp "$pp/$f" "$f"; done < "$pp/SHA256SUMS"
	while read -r o n f; do [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$n" ] || return 1; done < "$pp/SHA256SUMS"
}
# keep git from walking up into an enclosing repository (e.g. a clone of this kit)
CEIL=$(cd "$DIR/.." && pwd -P)
if patched; then
	say "debug patch already applied"
elif have patch && patch -p1 --dry-run -s -f < "$PATCH" >/dev/null 2>&1 && patch -p1 -s -f < "$PATCH" && patched; then
	say "applied patch with patch(1)"
elif have git && GIT_CEILING_DIRECTORIES=$CEIL git apply --check "$PATCH" 2>/dev/null &&
     GIT_CEILING_DIRECTORIES=$CEIL git apply "$PATCH" && patched; then
	say "applied patch with git apply"
elif copy_prepatched && patched; then
	say "no usable patch/git: copied pre-patched v7.3 files (checksums verified)"
else
	die "cannot apply $PATCH to this tree (install patch(1), or the tree is not v7.3)"
fi

# ---------------------------------------------------------------- 3. .config
if [ "$BASE" = defconfig ]; then
	say "base config: make defconfig (test build only)"
	make -s defconfig
else
	if [ -z "$BASE" ]; then
		if [ -r "/boot/config-$(uname -r)" ]; then BASE=/boot/config-$(uname -r)
		elif [ -r /proc/config.gz ]; then BASE=/proc/config.gz
		else die "no base config: /boot/config-$(uname -r) and /proc/config.gz are missing. Pass --base-config FILE."
		fi
	fi
	[ -r "$BASE" ] || die "base config not readable: $BASE"
	say "base config: $BASE"
	case "$BASE" in *.gz) zcat "$BASE" > .config ;; *) cp "$BASE" .config ;; esac
fi
scripts/kconfig/merge_config.sh -m .config "$HERE/config/cxl-debug.config" >/dev/null
# - distro configs reference signing certs / SBAT files / salts that only exist in the distro's packaging tree
# - a one-off debug kernel must not stop on a compiler/objtool warning (EL9/EL10 set WERROR) and must not
#   panic on an oops in the code being debugged (EL9 sets PANIC_ON_OOPS): the oops is what we want to read
# - RUST is never needed here and would pull in a toolchain
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
	--set-str SYSTEM_BLACKLIST_HASH_LIST "" --set-str MODULE_SIG_KEY "certs/signing_key.pem" \
	--set-str EFI_SBAT_FILE "" --set-str BUILD_SALT "" \
	--set-str LOCALVERSION "$LOCALVER" -d LOCALVERSION_AUTO \
	-d WERROR -d OBJTOOL_WERROR -d PANIC_ON_OOPS -d CMDLINE_OVERRIDE -d RUST
if [ "$KEEP_DEBUG_INFO" = 0 ]; then
	scripts/config -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -d DEBUG_INFO_DWARF4 -d DEBUG_INFO_DWARF5 -e DEBUG_INFO_NONE
fi
make -s olddefconfig

# adapt to what this host can actually run (an offline box cannot install a missing tool)
cfg() { grep -q "^CONFIG_$1=y" .config; }
changed=0
if cfg MODULE_COMPRESS; then
	for t in GZIP:gzip XZ:xz ZSTD:zstd; do
		if cfg "MODULE_COMPRESS_${t%%:*}" && ! have "${t#*:}"; then
			say "host has no ${t#*:}: turning module compression off"; scripts/config -d MODULE_COMPRESS; changed=1
		fi
	done
fi
for t in ZSTD:zstd LZ4:lz4 LZO:lzop XZ:xz BZIP2:bzip2 LZMA:lzma; do
	if cfg "KERNEL_${t%%:*}" && ! have "${t#*:}"; then
		say "host has no ${t#*:}: kernel image compression -> gzip"
		scripts/config -d "KERNEL_${t%%:*}" -e KERNEL_GZIP; changed=1
	fi
done
if cfg BUILTIN_MODULE_RANGES && ! have gawk; then
	say "host has no gawk: BUILTIN_MODULE_RANGES -> off (only used for modules.builtin.ranges)"
	scripts/config -d BUILTIN_MODULE_RANGES; changed=1
fi
[ "$changed" = 1 ] && make -s olddefconfig

dropped=0
while read -r l; do
	grep -qx "$l" .config && continue
	got=$(grep "^${l%%=*}=" .config || true)
	if [ "${l##*=}" = m ] && [ "$got" = "${l%=m}=y" ]; then
		say "note: ${l%%=*}=y (built in, selected by the base config) instead of =m - fine"
		continue
	fi
	echo "DROPPED: $l -> ${got:-not set}" >&2
	dropped=1
done < <(grep -E '^CONFIG_' "$HERE/config/cxl-debug.config")
[ "$dropped" = 0 ] || die "some fragment options did not survive olddefconfig (missing dependency in the base config); fix before building"
say "all fragment options present in .config"
onoff() { cfg "$1" && echo on || echo off; }
say "debug info: $(onoff DEBUG_INFO)  BTF: $(onoff DEBUG_INFO_BTF)  module compression: $(onoff MODULE_COMPRESS)  WERROR: $(onoff WERROR)"
say "built-in command line: $(sed -n 's/^CONFIG_CMDLINE=//p' .config)"

# ---------------------------------------------------------------- 4. host build dependencies
deps_rc=0
bash "$HERE/tools/check-build-deps.sh" --config .config --dir "$DIR" || deps_rc=$?

KREL=$mk$LOCALVER
if [ "$BUILD" = 1 ]; then
	[ "$deps_rc" = 0 ] || [ "$deps_rc" = 2 ] || die "missing build dependencies (see above); not starting the build"
	say "building with -j$JOBS, log: $DIR/build.log"
	start=$(date +%s)
	if ! make -j"$JOBS" > build.log 2>&1; then
		grep -nE 'error|Error [0-9]' build.log | head -20 >&2 || true
		tail -20 build.log >&2
		die "build failed; full log: $DIR/build.log"
	fi
	say "built $(make -s kernelrelease) in $(( ($(date +%s) - start) / 60 )) min"
fi
cat <<EOF
>> next (kernelrelease will be $KREL):
   cd $DIR$( [ "$BUILD" = 1 ] || printf '\n   make -j%s > build.log 2>&1      # build' "$JOBS")
   then RUNBOOK.md section F: pin the current kernel as the default FIRST, then
   sudo make INSTALL_MOD_STRIP=1 modules_install && sudo make install, then one-shot boot
EOF
