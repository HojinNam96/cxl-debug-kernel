#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Re-run cxl_pci probe on a device that currently has NO driver bound, with
# function_graph + return values limited to cxl_pci_probe, and save the trace
# and the dmesg delta. Never unbinds anything. Run as root.
#
#   sudo tools/reprobe-trace.sh 0000:xx:00.0 [outdir]
set -euo pipefail

BDF=${1:?usage: $0 <BDF> [outdir]}
OUT=${2:-reprobe-$BDF-$(date +%Y%m%d-%H%M%S)}
DEV=/sys/bus/pci/devices/$BDF
T=/sys/kernel/tracing
[ -d "$T/options" ] || T=/sys/kernel/debug/tracing

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$DEV" ] || { echo "no such PCI device: $BDF" >&2; exit 1; }
if [ -e "$DEV/driver" ]; then
	echo "$BDF is bound to $(basename "$(readlink "$DEV/driver")"); refusing (this script never unbinds)" >&2
	exit 1
fi
mkdir -p "$OUT"
dmesg > "$OUT/dmesg-before.txt"
if [ ! -d /sys/module/cxl_pci ]; then
	# loading the module probes every matching unbound device right away, before tracing is set up
	modprobe cxl_pci 2>/dev/null || true
	if [ -e "$DEV/driver" ]; then
		dmesg > "$OUT/dmesg-after.txt"
		diff "$OUT/dmesg-before.txt" "$OUT/dmesg-after.txt" | sed -n 's/^> //p' > "$OUT/dmesg-delta.txt" || true
		echo "loading cxl_pci probed and BOUND $BDF (it was simply not loaded before). See $OUT/dmesg-delta.txt" >&2
		exit 0
	fi
fi
[ -e /sys/bus/pci/drivers/cxl_pci/bind ] || { echo "cxl_pci driver not available (modinfo cxl_pci; kernel config CXL_PCI)" >&2; exit 1; }
[ -d "$T/options" ] || { echo "tracefs not found (CONFIG_FTRACE off?). Plain retry without trace: echo $BDF > /sys/bus/pci/drivers/cxl_pci/bind; dmesg | tail -50" >&2; exit 1; }

restore() {
	echo nop > "$T/current_tracer" 2>/dev/null || true
	echo > "$T/set_graph_function" 2>/dev/null || true
	echo 0 > "$T/max_graph_depth" 2>/dev/null || true
}
trap restore EXIT

echo nop > "$T/current_tracer"
echo > "$T/trace"
echo cxl_pci_probe > "$T/set_graph_function"
echo 8 > "$T/max_graph_depth"
echo function_graph > "$T/current_tracer"
echo 1 > "$T/options/funcgraph-retval" 2>/dev/null || echo "funcgraph-retval not available (CONFIG_FUNCTION_GRAPH_RETVAL)" >&2

set +e
echo "$BDF" > /sys/bus/pci/drivers/cxl_pci/bind 2> "$OUT/bind-result.txt"
rc=$?
set -e
echo "bind exit status: $rc" >> "$OUT/bind-result.txt"

cp "$T/trace" "$OUT/trace.txt"
dmesg > "$OUT/dmesg-after.txt"
diff "$OUT/dmesg-before.txt" "$OUT/dmesg-after.txt" | sed -n 's/^> //p' > "$OUT/dmesg-delta.txt" || true

cat "$OUT/bind-result.txt"
if ! grep -q cxl_pci_probe "$OUT/trace.txt"; then
	echo "NOTE: cxl_pci_probe never ran: the driver did not match the device (class code != 0x050210?)," \
	     "so 'No such device' here is a match failure, not a probe failure." | tee -a "$OUT/bind-result.txt"
fi
grep -E "cxl_pci_probe|$BDF" "$OUT/dmesg-delta.txt" | tail -40 || true
echo "saved in $OUT/"
