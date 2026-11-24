#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Check, without network and without installing anything, whether this host can build and install
# the v7.3 debug kernel. Prints every missing item with its Debian/Ubuntu, RHEL/Fedora and SUSE package.
# Exit status: 0 all present, 1 something needed to BUILD is missing, 2 only install/boot items missing
# (a build-only host may legitimately exit 2).
#
#   tools/check-build-deps.sh [--config .config] [--dir KERNEL_TREE] [--pkg deb|rpm]
# --config: also check the tools that this particular .config needs (compressors, gawk, pahole, libdw).
# --dir:    where the tree is / will be built (for the free-space check; default: current dir).
# --pkg:    also check the packaging tools for 'make bindeb-pkg' (deb) or 'make binrpm-pkg' (rpm).
# HOSTCFLAGS / HOSTLDFLAGS from the environment are used for the header compile tests, as Kbuild does.
set -u
CONFIG=""; DIR=$PWD; PKG=""
while [ $# -gt 0 ]; do
	case "$1" in
	--config) CONFIG=$2; shift 2 ;;
	--dir) DIR=$2; shift 2 ;;
	--pkg) PKG=$2; shift 2 ;;
	-h|--help) sed -n '3,12p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
*" debian "*|*" ubuntu "*) FAM=deb ;;
*" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) FAM=rpm ;;
*" suse "*|*" sles "*|*" opensuse "*) FAM=suse ;;
*) FAM=unknown ;;
esac

miss_req=(); miss_inst=(); miss_opt=(); pk_deb=(); pk_rpm=(); pk_suse=(); SB_ON=0
ok() { printf '  [ok]      %-30s %s\n' "$1" "${2:-}"; }
bad() { # bad required|install|optional "what" deb-pkg rpm-pkg suse-pkg "why"
	local lvl=$1 what=$2
	case $lvl in
	required) miss_req+=("$what"); printf '  [MISSING] %-30s %s\n' "$what" "$6" ;;
	install) miss_inst+=("$what"); printf '  [MISSING] %-30s %s (install/boot)\n' "$what" "$6" ;;
	*) miss_opt+=("$what"); printf '  [warn]    %-30s %s\n' "$what" "$6" ;;
	esac
	pk_deb+=("$3"); pk_rpm+=("$4"); pk_suse+=("$5")
}
have() { command -v "$1" >/dev/null 2>&1; }
tool() { # tool required|install|optional cmd deb rpm suse why
	if have "$2"; then ok "$2" "$(command -v "$2")"; else bad "$1" "$2" "$3" "$4" "$5" "$6"; fi
}
# vge MIN HAVE -> true if HAVE >= MIN
vge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
hdr() { # hdr level "header" "lib" deb rpm suse why
	local t; t=$(mktemp -d)
	printf '#include <%s>\nint main(void){return 0;}\n' "$2" > "$t/t.c"
	# shellcheck disable=SC2086  # HOSTCFLAGS/HOSTLDFLAGS: same env vars the kernel build honours
	if have gcc && gcc ${HOSTCFLAGS:-} "$t/t.c" -o "$t/t" ${HOSTLDFLAGS:-} ${3:+-l$3} >/dev/null 2>&1; then ok "<$2>${3:+ -l$3}"
	else bad "$1" "<$2>${3:+ -l$3}" "$4" "$5" "$6" "$7"; fi
	rm -rf "$t"
}

echo "== host: ${PRETTY_NAME:-unknown OS}, kernel $(uname -r), $(uname -m), $(nproc) CPUs, $(awk '/MemTotal/{printf "%d GiB", $2/1048576}' /proc/meminfo) RAM"
[ "$(uname -m)" = x86_64 ] || echo "  note: this kit was prepared for x86_64"

echo "== build tools"
tool required make  make make make "kernel build"
tool required gcc   gcc gcc gcc "compiler"
tool required ld    binutils binutils binutils "linker"
tool required flex  flex flex flex "Kconfig / genksyms lexer"
tool required bison bison bison bison "Kconfig / genksyms parser"
tool required bc    bc bc bc "kernel/time constants"
tool required perl  perl perl perl "headers / scripts"
tool required awk   gawk gawk gawk "scripts"
tool required tar   tar tar tar "unpack source, IKHEADERS"
tool required xz    xz-utils xz xz "unpack linux-*.tar.xz, IKHEADERS"
tool required gzip  gzip gzip gzip "IKCONFIG, gzip kernel image"
tool required openssl openssl openssl openssl "module signing key generation"
tool optional python3 python3 python3 python3 "tools/cxl_triage.py (not needed for the build)"
tool optional patch patch patch patch "patch apply (setup.sh falls back to pre-patched files)"

if have make; then
	mv=$(make --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
	if vge 4.0 "${mv:-0}"; then ok "make >= 4.0" "$mv"; else bad required "make >= 4.0 (have ${mv:-?})" make make make "top-level Makefile refuses older make"; fi
fi
if have gcc; then
	gv=$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)
	if vge 8.1.0 "$gv"; then ok "gcc >= 8.1" "$gv"; else bad required "gcc >= 8.1 (have $gv)" gcc gcc gcc "scripts/min-tool-version.sh"; fi
fi
if have ld; then
	bv=$(ld --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1)
	if vge 2.30.0 "$bv"; then ok "binutils >= 2.30" "$bv"; else bad required "binutils >= 2.30 (have $bv)" binutils binutils binutils "scripts/min-tool-version.sh"; fi
fi

echo "== development headers / libraries (compile test)"
hdr required gelf.h elf libelf-dev elfutils-libelf-devel libelf-devel "objtool (always built on x86_64)"
hdr required openssl/opensslv.h crypto libssl-dev openssl-devel libopenssl-devel "sign-file / extract-cert"

if [ -n "$CONFIG" ] && [ -r "$CONFIG" ]; then
	echo "== needed by this .config ($CONFIG)"
	c() { grep -qE "^CONFIG_$1=(y|m)" "$CONFIG"; }
	n=0
	if c MODULE_COMPRESS; then
		c MODULE_COMPRESS_ZSTD && { tool required zstd zstd zstd zstd "MODULE_COMPRESS_ZSTD"; n=1; }
		c MODULE_COMPRESS_XZ && { tool required xz xz-utils xz xz "MODULE_COMPRESS_XZ"; n=1; }
	fi
	c KERNEL_ZSTD && { tool required zstd zstd zstd zstd "KERNEL_ZSTD"; n=1; }
	c KERNEL_LZ4 && { tool required lz4 lz4 lz4 lz4 "KERNEL_LZ4"; n=1; }
	c KERNEL_LZO && { tool required lzop lzop lzop lzop "KERNEL_LZO"; n=1; }
	c KERNEL_BZIP2 && { tool required bzip2 bzip2 bzip2 bzip2 "KERNEL_BZIP2"; n=1; }
	c BUILTIN_MODULE_RANGES && { tool required gawk gawk gawk gawk "BUILTIN_MODULE_RANGES (scripts/Makefile.vmlinux)"; n=1; }
	c DEBUG_INFO_BTF && { tool required pahole dwarves dwarves dwarves "DEBUG_INFO_BTF"; n=1; }
	if c GENDWARFKSYMS; then
		hdr required elfutils/libdw.h dw libdw-dev elfutils-devel libdw-devel "GENDWARFKSYMS (scripts/gendwarfksyms)"
		hdr required zlib.h z zlib1g-dev zlib-devel zlib-devel "GENDWARFKSYMS"; n=1
	fi
	[ "$n" = 1 ] || echo "  (nothing beyond the list above)"
fi

if [ -n "$PKG" ]; then
	echo "== packaging ($PKG)"
	case $PKG in
	deb) tool required dpkg-buildpackage dpkg-dev - - "make bindeb-pkg"; tool required dh debhelper - - "make bindeb-pkg (debian/rules)";;
	rpm) tool required rpmbuild - rpm-build rpm-build "make binrpm-pkg";;
	*) echo "  unknown --pkg $PKG (deb|rpm)";;
	esac
	tool optional rsync rsync rsync rsync "headers install inside the package"
fi

echo "== install / boot (only needed on the machine that boots the debug kernel)"
tool install depmod kmod kmod kmod "modules_install"
# v7.3 scripts/install.sh runs ~/bin/installkernel or /sbin/installkernel; without either, x86 falls back
# to arch/x86/boot/install.sh, which only copies an unversioned /boot/vmlinuz and makes no initramfs.
if [ -x /sbin/installkernel ] || [ -x "${HOME:-/root}/bin/installkernel" ]; then ok "installkernel" "/sbin/installkernel"
else bad install "/sbin/installkernel" debianutils grubby systemd "make install would only copy /boot/vmlinuz; use 'sudo kernel-install add <ver> arch/x86/boot/bzImage' instead"; fi
ird=""
for t in dracut update-initramfs mkinitramfs mkinitcpio; do have $t && ird="$ird $t"; done
if [ -n "$ird" ]; then ok "initramfs generator" "$ird"; else bad install "dracut/initramfs-tools" initramfs-tools dracut dracut "initramfs for the new kernel"; fi
bl=""
for t in grub-reboot grub2-reboot grubby grub-set-default grub2-set-default update-grub grub2-mkconfig bootctl; do have $t && bl="$bl $t"; done
if [ -n "$bl" ]; then ok "boot loader tools" "$bl"; else bad optional "grub-reboot/grub2-reboot" grub2-common grub2-tools grub2 "one-shot boot"; fi

sb=unknown
if [ ! -d /sys/firmware/efi ]; then sb="legacy BIOS boot (no Secure Boot)"
elif have mokutil && mokutil --sb-state >/dev/null 2>&1; then sb=$(mokutil --sb-state 2>/dev/null | head -1)
else
	v=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
	[ -n "$v" ] && sb="SecureBoot $( [ "$(od -An -tu1 -j4 -N1 "$v" 2>/dev/null | tr -d ' ')" = 1 ] && echo enabled || echo disabled)"
fi
case "$sb" in
*enabled*) SB_ON=1; bad install "Secure Boot enabled" - - - "$sb: shim refuses a self-built kernel" ;;
*) ok "Secure Boot" "$sb" ;;
esac
ld=$(cat /sys/kernel/security/lockdown 2>/dev/null)
[ -n "$ld" ] && ok "lockdown (running kernel)" "$ld"

echo "== space"
d=$DIR; while [ ! -d "$d" ]; do d=$(dirname "$d"); done
need=25; [ -n "$CONFIG" ] && grep -q '^CONFIG_DEBUG_INFO=y' "$CONFIG" 2>/dev/null && need=60
fg=$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
if [ -n "$CONFIG" ] && [ -f "$d/vmlinux" ]; then ok "free space build dir" "${fg} GiB in $d (tree already built)"
elif [ "${fg:-0}" -ge "$need" ]; then ok "free space build dir" "${fg} GiB in $d (need ~$need)"
else bad required "free space build dir" - - - "${fg:-?} GiB in $d, need ~$need GiB"; fi
mnt_opts=$(findmnt -no OPTIONS -T "$d" 2>/dev/null)
case ",$mnt_opts," in *,noexec,*) bad required "exec on build dir" - - - "$d is mounted noexec: build/scripts cannot run there" ;; esac
fb=$(df -Pk /boot 2>/dev/null | awk 'NR==2{print int($4/1024)}')
if [ "${fb:-0}" -ge 300 ]; then ok "free space /boot" "${fb} MiB"; else bad install "free space /boot" - - - "${fb:-?} MiB, need ~300 MiB (remove an old kernel)"; fi
fm=$(df -Pk /lib/modules 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
if [ "${fm:-0}" -ge 2 ]; then ok "free space /lib/modules" "${fm} GiB"; else bad install "free space /lib/modules" - - - "${fm:-?} GiB, need ~2 GiB (with INSTALL_MOD_STRIP=1)"; fi

echo
uniq_pk() { printf '%s\n' "$@" | grep -v '^-$' | sort -u | tr '\n' ' '; }
pkgline() {
	local l
	case $FAM in
	deb) l=$(uniq_pk "${pk_deb[@]}"); [ -n "${l// /}" ] && echo "    sudo apt-get install $l" ;;
	rpm) l=$(uniq_pk "${pk_rpm[@]}"); [ -n "${l// /}" ] && echo "    sudo dnf install $l" ;;
	suse) l=$(uniq_pk "${pk_suse[@]}"); [ -n "${l// /}" ] && echo "    sudo zypper install $l" ;;
	*) echo "    Debian/Ubuntu: $(uniq_pk "${pk_deb[@]}")"; echo "    RHEL/Fedora:   $(uniq_pk "${pk_rpm[@]}")" ;;
	esac
	return 0
}
sbnote() { [ "$SB_ON" = 1 ] && echo "  Secure Boot: turn it off in BIOS setup (BMC console) before RUNBOOK.md section F, or sign the kernel with an enrolled MOK."; return 0; }
if [ ${#miss_req[@]} -eq 0 ] && [ ${#miss_inst[@]} -eq 0 ]; then
	echo "RESULT: OK - everything needed to build and install is present${miss_opt[0]:+ (warnings: ${miss_opt[*]})}"
	exit 0
fi
if [ ${#miss_req[@]} -eq 0 ]; then
	echo "RESULT: can BUILD here; missing for install/boot only: ${miss_inst[*]}"
	echo "  (fine on a build-only machine; on the machine that boots the kernel fix these before RUNBOOK.md F:)"
	pkgline; sbnote
	exit 2
fi
echo "RESULT: MISSING ${#miss_req[@]} item(s) needed to build: ${miss_req[*]}${miss_inst[0]:+   (install/boot: ${miss_inst[*]})}"
echo "  install from the internal package mirror, if there is one:"
pkgline; sbnote
echo "  no mirror: RUNBOOK.md section B '빠진 패키지 반입' (OS: ${PRETTY_NAME:-unknown})."
exit 1
