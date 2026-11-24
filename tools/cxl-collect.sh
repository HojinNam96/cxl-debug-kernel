#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Collect every BIOS- and OS-level fact needed to tell WHERE a CXL Type 3 device stops on its way to
# memN / regionN / daxX.Y, run tools/cxl_triage.py, and pack everything into one tar.gz. Run as root.
#
#   sudo tools/cxl-collect.sh [--bdf 0000:xx:yy.z] [--enable-dyndbg] [--tag NAME] [--outdir DIR]
#                             [--no-mmio] [--with-mbox]
#
# Read-only by default: nothing is bound, unbound or reset, and no CXL mailbox command is sent.
# It reads config space, ACPI tables, sysfs (cached values) and dmesg; cxl_triage.py also reads a few
# MMIO status/decoder registers (plain loads, skipped when Memory Space is disabled; --no-mmio skips all).
# --with-mbox additionally runs 'cxl list -vvv', which DOES send mailbox queries to each memdev
#             (Get Health Info, Get Partition Info, Get Poison List, ...). Off by default.
# --enable-dyndbg writes "+pmf" for the CXL/DAX modules into /proc/dynamic_debug/control (more dmesg
# output from now on; affects nothing else). It only covers modules that are already loaded.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BDF=""; DYNDBG=0; TAG=""; OUTDIR=$PWD; NOMMIO=""; MBOX=0
while [ $# -gt 0 ]; do
	case "$1" in
	--bdf) BDF=$2; shift 2 ;;
	--enable-dyndbg) DYNDBG=1; shift ;;
	--tag) TAG=-$2; shift 2 ;;
	--outdir) OUTDIR=$2; shift 2 ;;
	--no-mmio) NOMMIO=--no-mmio; shift ;;
	--with-mbox) MBOX=1; shift ;;
	-h|--help) sed -n '3,15p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ "$(id -u)" = 0 ] || { echo "run as root (config space, ACPI tables, iomem addresses and dmesg need it)" >&2; exit 1; }
if [ -n "$BDF" ]; then
	case "$BDF" in ????:??:??.?) ;; ??:??.?) BDF=0000:$BDF ;; esac      # accept lspci's short form
	[ -e "/sys/bus/pci/devices/$BDF" ] || { echo "no such PCI device: $BDF (use the full form 0000:bb:dd.f, see lspci -D)" >&2; exit 1; }
fi

NAME=cxl-collect-$(uname -r)$TAG-$(date +%Y%m%d-%H%M%S)
O=$OUTDIR/$NAME
mkdir -p "$O"/{boot,acpi,pci,mem,cxl,dax,log}
echo ">> collecting into $O"

have() { command -v "$1" >/dev/null 2>&1; }
# run FILE CMD...: save stdout+stderr, never abort, cap runtime
run() { local f=$1; shift; { echo "\$ $*"; timeout 60 "$@"; echo "[exit $?]"; } > "$O/$f" 2>&1; }
# dump every readable attribute file under a sysfs dir (no binary-ish or action files)
dumpattrs() {
	find -L "$1" -maxdepth "${2:-1}" -type f -readable \
		! -name uevent ! -name remove ! -name bind ! -name unbind ! -name new_id ! -name remove_id \
		! -name rescan ! -name reset ! -name 'trigger_*' ! -name config ! -name 'resource[0-9]*' \
		! -name rom ! -name vpd ! -name cdat ! -name data ! -name label ! -name sanitize \
		! -name acpi_index ! -name wait_probe ! -path '*/security/state' \
		2>/dev/null | sort | while read -r f; do
		printf '%s = %s\n' "$f" "$(timeout 2 head -c 512 "$f" 2>&1 | tr '\n' ' ')"
	done
}

### optional: dynamic debug for already-loaded modules
if [ "$DYNDBG" = 1 ]; then
	C=/proc/dynamic_debug/control
	[ -w $C ] || C=/sys/kernel/debug/dynamic_debug/control
	if [ -w "$C" ]; then
		for m in cxl_core cxl_acpi cxl_pci cxl_mem cxl_port cxl_pmem dax dax_cxl dax_hmem kmem device_dax; do
			if grep -q "\[$m\]" "$C" 2>/dev/null; then
				echo "module $m +pmf" > "$C" && echo "   dyndbg on: $m ($(grep -c "\[$m\]" "$C") sites)"
			else
				echo "   dyndbg skip: $m (not loaded / no debug sites)"
			fi
		done
	else
		echo "   dynamic_debug control not writable (CONFIG_DYNAMIC_DEBUG off, or lockdown)" >&2
	fi
fi

### boot / kernel / platform firmware identity
run boot/uname.txt uname -a
cat /proc/cmdline > "$O/boot/cmdline.txt" 2>&1
cat /etc/os-release > "$O/boot/os-release.txt" 2>&1
if [ -r /proc/config.gz ]; then zcat /proc/config.gz > "$O/boot/kernel-config.txt"
elif [ -r "/boot/config-$(uname -r)" ]; then cp "/boot/config-$(uname -r)" "$O/boot/kernel-config.txt"; fi
[ -f "$O/boot/kernel-config.txt" ] && grep -E 'CONFIG_(CXL|DEV_DAX|DAX|EFI_SOFT_RESERVE|MEMORY_HOTPLUG|ACPI_PRMT|AMD_NB|DYNAMIC_DEBUG|NUMA_KEEP_MEMINFO|LOCALVERSION)' \
	"$O/boot/kernel-config.txt" > "$O/boot/kernel-config-cxl.txt"
have dmidecode && run boot/dmidecode-bios-system.txt dmidecode -t bios -t system -t baseboard -t processor
have mokutil && run boot/secureboot.txt mokutil --sb-state
cat /sys/kernel/security/lockdown > "$O/boot/lockdown.txt" 2>&1
ls /sys/firmware/efi >/dev/null 2>&1 && echo "UEFI boot" > "$O/boot/efi.txt" || echo "legacy boot (no /sys/firmware/efi)" > "$O/boot/efi.txt"

### BIOS hand-off: ACPI tables, memory map
for t in CEDT SRAT HMAT SLIT CDIT DSDT MCFG; do
	[ -r /sys/firmware/acpi/tables/$t ] && cp /sys/firmware/acpi/tables/$t "$O/acpi/$t.dat"
done
ls -la /sys/firmware/acpi/tables/ > "$O/acpi/tables-list.txt" 2>&1
if have iasl; then
	( cd "$O/acpi" && for t in CEDT SRAT HMAT; do [ -f $t.dat ] && iasl -d $t.dat >/dev/null 2>&1; done )
else
	echo "iasl not installed (apt install acpica-tools / dnf install acpica-tools); raw .dat tables saved" > "$O/acpi/README.txt"
fi
for d in /sys/bus/acpi/devices/ACPI0016:* /sys/bus/acpi/devices/ACPI0017:* /sys/bus/acpi/devices/ACPI0010:*; do
	[ -e "$d" ] || continue
	printf '%s  status=%s  uid=%s  path=%s  physical_node=%s\n' "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)" \
		"$(cat "$d/uid" 2>/dev/null)" "$(cat "$d/path" 2>/dev/null)" "$(readlink -f "$d/physical_node" 2>/dev/null)"
done > "$O/acpi/acpi-cxl-devices.txt"
cp /proc/iomem "$O/mem/iomem.txt"
for d in /sys/firmware/memmap/*; do
	printf '%s %s-%s %s\n' "$(basename "$d")" "$(cat "$d/start")" "$(cat "$d/end")" "$(cat "$d/type")"
done 2>/dev/null | sort -n > "$O/mem/firmware-memmap.txt"
run mem/lsmem.txt lsmem -a -o RANGE,SIZE,STATE,REMOVABLE,BLOCK,NODE,ZONES
have numactl && run mem/numactl-H.txt numactl -H
for n in /sys/devices/system/node/node*; do echo "== $n"; head -5 "$n/meminfo"; cat "$n/cpulist"; done > "$O/mem/nodes.txt" 2>&1
cat /proc/meminfo > "$O/mem/meminfo.txt"

### PCI
run pci/lspci-tv.txt lspci -tv
run pci/lspci-nnk.txt lspci -nn -k
CXLDEVS=$(for d in /sys/bus/pci/devices/*; do
	c=$(cat "$d/class"); case "$c" in 0x0502*) basename "$d" ;; esac; done)
[ -n "$BDF" ] && CXLDEVS=$(printf '%s\n%s\n' "$CXLDEVS" "$BDF" | sort -u)
echo "$CXLDEVS" > "$O/pci/cxl-class-devices.txt"
for b in $CXLDEVS; do
	[ -e "/sys/bus/pci/devices/$b" ] || continue
	{
		echo "### device $b (class $(cat /sys/bus/pci/devices/$b/class))"
		lspci -vvv -xxxx -s "$b"
		p=$(readlink -f "/sys/bus/pci/devices/$b")
		while p=$(dirname "$p"); [ -e "$p/config" ]; do
			u=$(basename "$p")
			echo; echo "### upstream $u"; lspci -vvv -xxxx -s "$u"
		done
		echo; echo "### sysfs attrs $b"; dumpattrs "/sys/bus/pci/devices/$b"
		echo "driver -> $(readlink "/sys/bus/pci/devices/$b/driver" 2>/dev/null || echo NONE)"
	} > "$O/pci/dev-$b.txt" 2>&1
done
have setpci || echo "setpci missing" > "$O/pci/NOTE.txt"

### CXL / DAX objects
run cxl/ls-cxl-devices.txt ls -la /sys/bus/cxl/devices/
run cxl/ls-cxl-drivers.txt ls -la /sys/bus/cxl/drivers/
for d in /sys/bus/cxl/devices/*; do
	[ -e "$d" ] || continue
	echo "===== $(basename "$d") -> $(readlink -f "$d")"
	echo "driver -> $(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null || echo NONE)"
	dumpattrs "$d" 2
done > "$O/cxl/sysfs-cxl-all.txt" 2>&1
# -vv lists buses/ports/endpoints/decoders/regions from sysfs only; -vvv adds mailbox queries (opt-in)
if have cxl; then
	run cxl/cxl-list.txt cxl list -vv; run cxl/cxl-list-idle.txt cxl list -vv -i
	[ "$MBOX" = 1 ] && run cxl/cxl-list-vvv-mbox.txt cxl list -vvv
fi
have daxctl && run dax/daxctl-list.txt daxctl list -vvv
run dax/ls-dax-devices.txt ls -la /sys/bus/dax/devices/
for d in /sys/bus/dax/devices/*; do [ -e "$d" ] && { echo "===== $(basename "$d")"; dumpattrs "$d" 2; }; done > "$O/dax/sysfs-dax-all.txt" 2>&1
lsmod | grep -E '^(cxl|dax|device_dax|kmem|nd_|libnvdimm)' > "$O/cxl/lsmod.txt" 2>&1
for m in cxl_core cxl_acpi cxl_pci cxl_mem cxl_port cxl_pmem dax_cxl dax_hmem kmem device_dax; do
	[ -d /sys/module/$m/parameters ] && for p in /sys/module/$m/parameters/*; do echo "$m.$(basename "$p")=$(cat "$p")"; done
done > "$O/cxl/module-params.txt" 2>&1
[ -r /sys/kernel/debug/devices_deferred ] && cp /sys/kernel/debug/devices_deferred "$O/cxl/devices_deferred.txt"
C=/proc/dynamic_debug/control; [ -r $C ] || C=/sys/kernel/debug/dynamic_debug/control
[ -r "$C" ] && grep -E '\[(cxl|dax|kmem|device_dax)' "$C" > "$O/log/dyndbg-cxl-sites.txt"

### logs
dmesg -T > "$O/log/dmesg-T.txt" 2>&1
dmesg > "$O/log/dmesg.txt" 2>&1
have journalctl && journalctl -k -b --no-pager > "$O/log/journal-k-this-boot.txt" 2>&1
have journalctl && journalctl -k -b -1 --no-pager > "$O/log/journal-k-prev-boot.txt" 2>&1
D=$O/log/dmesg.txt
{
	echo "## firmware memory map / soft reserved / EFI SP"
	grep -iE 'BIOS-e820|soft reserved|efi: mem.*(SP|MORE|CXL)|EFI_MEMORY_SP|reserve setup_data' $D
	echo; echo "## ACPI tables and NUMA"
	grep -E 'ACPI: (CEDT|SRAT|HMAT|SLIT|CDIT)|SRAT: Node|NUMA: |node [0-9]+: \[mem|Faking a node|CFMWS|CHBS|CXL Window' $D
	echo; echo "## CXL / DAX driver lines"
	grep -iE 'cxl|dax|hmem|kmem' $D
	echo; echo "## probe results (initcall_debug)"
	grep -E 'probe of .* returned' $D | grep -viE 'returned 0 after' 
	echo; echo "## AER / PCIe errors / link"
	grep -iE 'AER|pcieport|link (up|down)|Correctable|Uncorrect|DPC' $D
	if [ -n "$CXLDEVS" ]; then echo; echo "## lines naming CXL-class BDFs"; for b in $CXLDEVS; do grep -F "$b" $D; done; fi
} > "$O/log/dmesg-summary.txt" 2>&1

### triage ladder
if [ -f "$HERE/cxl_triage.py" ]; then
	args=$NOMMIO; [ -n "$BDF" ] && args="$args --bdf $BDF"
	# shellcheck disable=SC2086
	timeout 180 python3 "$HERE/cxl_triage.py" $args > "$O/TRIAGE.txt" 2>&1 || echo "[triage exit $?]" >> "$O/TRIAGE.txt"
fi

### short summary on screen + in the tar
{
	echo "kernel: $(uname -r)    cmdline: $(cat /proc/cmdline)"
	echo "bios:   $(cat /sys/class/dmi/id/bios_vendor /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date 2>/dev/null | tr '\n' ' ')"
	echo "ACPI tables present: $(cd /sys/firmware/acpi/tables && ls -d CEDT SRAT HMAT 2>/dev/null | tr '\n' ' ')"
	echo "ACPI0017 (CXL root): $(ls -d /sys/bus/acpi/devices/ACPI0017:* 2>/dev/null | wc -l)  ACPI0016 (CXL host bridge): $(ls -d /sys/bus/acpi/devices/ACPI0016:* 2>/dev/null | wc -l)"
	echo "firmware memmap Soft Reserved: $(grep -ci 'soft reserved' "$O/mem/firmware-memmap.txt")   iomem CXL/Soft Reserved lines: $(grep -ciE 'cxl|soft reserved' "$O/mem/iomem.txt")"
	echo "cxl objects: $(ls /sys/bus/cxl/devices 2>/dev/null | tr '\n' ' ')"
	echo "dax devices: $(ls /sys/bus/dax/devices 2>/dev/null | tr '\n' ' ')"
	for b in $CXLDEVS; do
		drv=$(basename "$(readlink "/sys/bus/pci/devices/$b/driver" 2>/dev/null)" 2>/dev/null)
		mem=$(ls -d /sys/bus/pci/devices/$b/mem* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
		echo "PCI $b class=$(cat /sys/bus/pci/devices/$b/class) driver=${drv:-NONE} memdev=${mem:-NONE}"
	done
	echo; echo "---- first cxl_pci_probe / failed lines (first 40) ----"
	grep -E 'cxl_pci_probe|failed|rejects match|returned -' "$O/log/dmesg.txt" | grep -iE 'cxl|dax|mem[0-9]|port[0-9]|region|decoder' | head -40
	echo; echo "---- triage first failing stage ----"
	sed -n '/^VERDICT/,/^ *$/p' "$O/TRIAGE.txt" 2>/dev/null | head -25
} > "$O/SUMMARY.txt" 2>&1

# SHORT.txt: the ~15 lines to copy by hand when no file may leave the network
{
	echo "K $(uname -r) | BIOS $(cat /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date 2>/dev/null | tr '\n' ' ')| cmdline-has-initcall_debug=$(grep -qw initcall_debug /proc/cmdline && echo y || echo n)"
	echo "ACPI $(cd /sys/firmware/acpi/tables 2>/dev/null && for t in CEDT SRAT HMAT; do [ -e $t ] && printf '%s=y ' $t || printf '%s=n ' $t; done)ACPI0017=$(ls -d /sys/bus/acpi/devices/ACPI0017:* 2>/dev/null | wc -l) ACPI0016=$(ls -d /sys/bus/acpi/devices/ACPI0016:* 2>/dev/null | wc -l) | memmap-SoftReserved=$(grep -ci 'soft reserved' "$O/mem/firmware-memmap.txt") | CFMWS/CHBS lines: $(grep -c -E 'CFMWS|CHBS' "$O/TRIAGE.txt" 2>/dev/null)"
	grep '^PCI ' "$O/SUMMARY.txt"
	echo "cxl: mem=$(ls -d /sys/bus/cxl/devices/mem* 2>/dev/null | wc -l) endpoint=$(ls -d /sys/bus/cxl/devices/endpoint* 2>/dev/null | wc -l) region=$(ls -d /sys/bus/cxl/devices/region* 2>/dev/null | wc -l) decoder=$(ls -d /sys/bus/cxl/devices/decoder* 2>/dev/null | wc -l)  dax=$(ls /sys/bus/dax/devices 2>/dev/null | tr '\n' ' ')"
	if [ -n "$BDF" ]; then
		echo "DUT $BDF first lines:"
		grep -F "$BDF" "$O/log/dmesg.txt" | grep -E 'cxl_pci_probe|probe of|rejects match|failed|Media|mailbox|registers' | head -4 | cut -c1-200
	fi
	sed -n '/^VERDICT/,/^ *$/p' "$O/TRIAGE.txt" 2>/dev/null | grep -E 'first failing stage|evidence|meaning|next' | head -4 | cut -c1-240
} > "$O/SHORT.txt" 2>&1
cat "$O/SUMMARY.txt"
echo; echo "======== SHORT.txt (copy these lines if files cannot leave the network) ========"
cat "$O/SHORT.txt"

tar -C "$OUTDIR" -czf "$OUTDIR/$NAME.tar.gz" "$NAME"
echo
echo ">> full TRIAGE: $O/TRIAGE.txt"
echo ">> archive:     $OUTDIR/$NAME.tar.gz"
