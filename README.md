# cxl-debug-kernel

A Linux **v7.3** (mainline tag from torvalds/linux) debug build for finding out why a CXL Type 3 memory device does not register (no `memN`, no region, no `daxX.Y`). With it, every failure in the CXL/DAX stack is printed in `dmesg`, and you do not have to set up dynamic debug by hand.

This repository holds the patch, a Kconfig fragment, boot parameters, helper scripts **and the complete Linux 7.3 source** in `linux-7.3/`: the unmodified kernel.org `linux-7.3.tar.xz` (commit `af4699c`), with the debug patch applied on top (commit `cedffd1`). `setup.sh` builds the whole kernel from it. A machine **without internet access** gets everything as one file, in one of two ways:
- **This repository:** download [main.tar.gz](https://github.com/HojinNam96/cxl-debug-kernel/archive/refs/heads/main.tar.gz) (saved as `cxl-debug-kernel-main.tar.gz`), or `git clone` on Linux/WSL, and carry it in. **Do not extract or clone it on Windows itself.** 13 pairs of kernel paths differ only in case and there are 102 symlinks, so a Windows checkout silently loses or breaks files.
- **The offline bundle** from the [Releases](https://github.com/HojinNam96/cxl-debug-kernel/releases) page (made by `make-offline-bundle.sh`): the kernel.org tarball, which can be checked against kernel.org's checksums and signature, plus the kit. It is 155 MiB, with 95 MB parts for transfer systems that have a size limit.

Offline target (no network used at any step; full sequence with the boot-loader steps in `RUNBOOK.md`):
```bash
# repository archive:  (a tarred clone unpacks to cxl-debug-kernel/ instead)
tar -xzf cxl-debug-kernel-main.tar.gz && cd cxl-debug-kernel-main
# or the offline bundle:
tar -xf cxl-debug-kernel-offline-v7.3.tar && cd cxl-debug-kernel-offline-v7.3 && sha256sum -c --quiet SHA256SUMS && cd cxl-debug-kernel

tools/check-build-deps.sh                                   # what is missing to build/install, with package names
nohup ./setup.sh --build > setup.log 2>&1 &                 # builds the whole kernel in ./linux-7.3, log: linux-7.3/build.log
sudo tools/cxl-collect.sh --bdf 0000:xx:00.0 --tag distro   # distro-kernel baseline while it builds
wait; tail -3 setup.log                                     # must show '>> built 7.3.0-cxldbg'
# pin the current kernel as the default boot entry FIRST (RUNBOOK.md F), then:
(cd linux-7.3 && sudo make INSTALL_MOD_STRIP=1 modules_install && sudo make install)
# one-shot boot into 7.3.0-cxldbg (grub-reboot / grub2-reboot), then from this directory:
sudo tools/cxl-collect.sh --bdf 0000:xx:00.0 --tag cxldbg
```
If neither `./linux-7.3` nor a tarball is present (the kit copied without the source), `./setup.sh` falls back to a shallow `git clone` of v7.3 from torvalds/linux, which needs internet.

See `RUNBOOK.md` for the full one-session sequence (Korean), including what to do when build packages are missing on a closed network.

## Why kernel parameters alone are not enough

Turning on every dynamic-debug site still leaves exits in `cxl_pci_probe()` that print nothing at any level:
- No Register Locator DVSEC: `-ENXIO` (`drivers/cxl/core/regs.c:317`).
- No CXL Device Registers block (Block ID 03h): `-ENODEV` (`regs.c:345`).

The driver core reports `-ENXIO` and `-ENODEV` only at debug level (`drivers/base/dd.c:636-640`). Several other exits come after `devm_cxl_add_classdev()`, so the `memN` that was just created is devm-removed again and leaves no trace.

## Contents

| file | what it does |
|---|---|
| `linux-7.3/` | The complete Linux 7.3 source (96,080 entries). Commit `af4699c` holds kernel.org `linux-7.3.tar.xz` (sha256 `87363c24…f004953`) unpacked and unmodified. Commit `cedffd1` applies the patch below to it. |
| `patches/0001-cxl-dax-debug-output.patch` | Adds `-DDEBUG` to `drivers/cxl` (+`core/`) and `drivers/dax` (+`hmem/`), so every `dev_dbg`/`pr_debug` there is enabled by default (`include/linux/dynamic_debug.h:48`). In `cxl_pci_probe()`, every early return logs `cxl_pci_probe: <step> failed: <rc> (<errno>)` at KERN_ERR, and success logs `cxl_pci_probe: done, memN registered`. |
| `config/cxl-debug.config` | The Kconfig fragment. The CXL/DAX stack is built as modules, like distros do, including `CXL_REGION` and `CXL_ATL` (the AMD PRM address translation). The boot parameters (`log_buf_len=64M initcall_debug efi=debug panic=30`) are built in with `CONFIG_CMDLINE`, so no boot-loader edit is needed. It also turns on `DEBUG_DRIVER`, `PCI_DEBUG`, `DYNAMIC_DEBUG`, `FUNCTION_GRAPH_RETVAL`, kprobe/BPF events, a 32 MB log buffer and `IKCONFIG_PROC`. |
| `cmdline.txt` | What the built-in boot parameters do, optional extras, and a per-module `dyndbg` fallback for kernels built without the patch. |
| `setup.sh` | Uses `./linux-7.3`, or else unpacks `linux-7.3.tar.xz` from next to the kit or from `--tarball` (both offline). Only otherwise does it make a shallow clone from torvalds/linux. It then applies the patch, skipping this step when the tree is already patched (`patch`, else `git apply`, else checksum-verified copies from `patches/prepatched-v7.3/`), and merges the fragment onto the running kernel's config (`/boot/config-$(uname -r)` or `/proc/config.gz`). It then runs `olddefconfig` and **fails if any fragment option was dropped**. It clears distro signing-cert and SBAT paths, sets `LOCALVERSION=-cxldbg`, and turns DWARF debug info off unless `--keep-debug-info`. It also turns off `WERROR`/`OBJTOOL_WERROR`, `PANIC_ON_OOPS` and `RUST` from distro configs, accepts an `=m` request that a built-in option forced to `=y`, and adapts to missing host tools: no `zstd`/`lz4` means no module compression and a gzip kernel image, no `gawk` means no `BUILTIN_MODULE_RANGES`. Finally it runs `tools/check-build-deps.sh`, and with `--build` it builds. |
| `make-offline-bundle.sh` | Run where there is internet: downloads `linux-7.3.tar.xz` from kernel.org, checks it against kernel.org's `sha256sums.asc` (and the PGP signature if gpg can fetch the keys), and writes `cxl-debug-kernel-offline-v7.3.tar` with `SHA256SUMS`. The committed `linux-7.3/` is left out, since the tarball replaces it. `--split 95M` cuts it into parts. |
| `tools/check-build-deps.sh` | Offline, read-only check of everything needed to build (compiler/binutils versions, flex/bison/bc/perl, libelf and openssl headers by compile test, tools the `.config` needs) and to install (depmod, installkernel, initramfs generator, space in `/boot` and `/lib/modules`, Secure Boot). Prints the missing packages for apt/dnf/zypper. |
| `RUNBOOK.md` | Step-by-step plan for one session on the target (Korean): build in the background, collect on the distro kernel, re-probe without reboot, one-shot boot of the debug kernel, collect again, compare with a working device. |
| `tools/cxl-collect.sh` | Read-only collector, run as root (no bind/unbind/reset, no mailbox command; `--with-mbox` opts into `cxl list -vvv`): BIOS version, ACPI CEDT/SRAT/HMAT (raw + iasl), ACPI0016/0017, `/sys/firmware/memmap`, `/proc/iomem`, `lspci -vvv -xxxx` of every class-0502 function and its upstream ports, all `/sys/bus/cxl` and dax attributes, NUMA, modules, dmesg/journal and a grep summary. Runs `cxl_triage.py`, writes `SUMMARY.txt` and a ~15-line `SHORT.txt` for copying by hand, and packs everything into one tar.gz. `--enable-dyndbg` turns on dev_dbg for loaded CXL/DAX modules. |
| `tools/cxl_triage.py` | Read-only ladder (DEVICE / BIOS / KERNEL / BYDESIGN) that prints the first failing stage between the PCI function and `/dev/daxX.Y`, with its owner. Tested on synthetic sysfs trees only. |
| `tools/reprobe-trace.sh` | Retries the probe of a device that currently has **no driver bound**, using `function_graph` with return values limited to `cxl_pci_probe`. Saves the trace, the bind errno and the dmesg delta. It never unbinds anything. |

Tested (2026-11-24, gcc 15.2 host, inside `unshare -rn` = no network): the offline bundle unpacks, patches (also with neither `patch` nor `git` present) and builds a complete `7.3.0-cxldbg` kernel from x86_64_defconfig with 0 warnings. `setup.sh` was run against the real distro configs of Ubuntu 24.04 (6.8), Ubuntu 26.04 (7.0), Rocky 9 (5.14) and AlmaLinux 10 (6.12); see RUNBOOK.md "검증" for per-distro results. Not tested on CXL hardware yet.

## Requirements and notes
- Build dependencies (Debian/Ubuntu): `build-essential flex bison bc gawk libelf-dev libssl-dev` (`dwarves` only with `--keep-debug-info`). `tools/check-build-deps.sh` lists exactly what is missing on the host.
- **Secure Boot:** shim refuses the self-built kernel, so turn Secure Boot off in BIOS setup (or enroll a MOK and sign vmlinuz). Under Secure Boot the distro kernel runs `lockdown=integrity`: PCI BAR mmap (the cxl_triage MMIO reads) and debugfs writes are refused, while tracefs, kprobes and `/proc/dynamic_debug/control` keep working. Mainline v7.3 has no "lock down in Secure Boot" option, so the debug kernel itself is not locked down.
- **Default boot entry:** on Ubuntu, `make install` makes 7.3.0-cxldbg GRUB entry 0 (highest version), and RHEL's installkernel makes it the default when `UPDATEDEFAULT=yes`. Pin the distro kernel as the default first, then `grub-reboot`/`grub2-reboot` the debug entry once (`RUNBOOK.md` F).
- The debug output is large. `ignore_loglevel` is not needed, because `dmesg` already shows every level, and it can stall boot on a slow serial console.
- **Control experiment:** if a known-good CXL device is available, check first that it still forms its region on this kernel. Its log is the reference to diff against.

## Reading the output

```bash
B=0000:xx:00.0                                    # device BDF
dmesg -T > dmesg-cxldbg.txt
grep -E "$B|cxl_pci_probe|probe of $B" dmesg-cxldbg.txt
grep -E 'probe of (mem|endpoint|port|region|dax_region|decoder)[0-9.]+ with driver' dmesg-cxldbg.txt
grep -iE 'BIOS-e820|soft reserved|efi: mem.*SP|ACPI: (CEDT|SRAT|HMAT) |CXL Window|host supports CXL|CHBS|CFMWS' dmesg-cxldbg.txt
```

### First failing `cxl_pci_probe` step

Spec references are to CXL 3.2. File and line references are to v7.3 (in v7.3.5, dd.c lines are +1).

| failing step | rc / preceding line | meaning | look at |
|---|---|---|---|
| no `cxl_pci_probe` line for the BDF | - | cxl_pci never probed it: the class code is not 0x050210, or the PCI core failed the device first | `lspci -nn -k -s $B`, PCI_DEBUG lines for the BDF |
| `pcim_enable_device` | any | PCI enable failed (BARs/resources) | PCI core messages |
| `cxl_pci_setup_regs(MEMDEV)` | -ENXIO, nothing before it | no Register Locator DVSEC (DVSEC ID 8) | §8.1.9 |
| `cxl_pci_setup_regs(MEMDEV)` | -ENXIO after `registers not found: status mbox memdev` | the CXL Device register block lacks the Device Status, Primary Mailbox or Memory Device capability | §8.2.9 capability array |
| `cxl_pci_setup_regs(MEMDEV)` | -ENODEV | no Block ID 03h entry, or its offset lies outside the BAR (preceded by `BAR%d: ... too small`, for example an unassigned BAR) | §8.1.9.1 |
| `cxl_pci_setup_regs(MEMDEV)` | -ENOMEM after `failed to map registers` | ioremap failed | BAR / iomem |
| `cxl_pci_setup_mailbox` | -ETIMEDOUT / -ENXIO | `timeout awaiting mailbox ready` or `Mailbox is too small` | Memory Device Status (Mailbox Interface Ready), Mailbox Capabilities |
| `cxl_pci_type3_init_mailbox` | any | kernel-side mailbox init, not a device register | - |
| `cxl_enumerate_cmds` | any | Get Supported Logs / CEL failed. The mailbox `dev_dbg` lines show the command and its return code | device mailbox command support |
| `cxl_dev_state_identify` / `cxl_mem_dpa_fetch` / `cxl_dpa_setup` | any | Identify Memory Device / Get Partition Info failed or is inconsistent | Identify payload |
| `devm_cxl_add_classdev` or later | any | memN was created and then devm-removed | the step named |
| `Media not active (rc)` (warning only) | -110 / -5 | the probe continues, and memN is still created with `ram/size` = 0 | DVSEC Range Memory_Info_Valid / Memory_Active, Media Status |

Once cxl_pci succeeds, the later stages (cxl_acpi/CEDT, port and endpoint enumeration, region auto-assembly, dax) print their reasons through the `-DDEBUG` lines and the `initcall_debug` lines of the form `probe of <dev> with driver <drv> returned <rc>`. Examples: `... is a root dport`, `no CXL window for range`, `failed to attach`, `config state`, `has System RAM`.

### Retry without rebooting
A failed probe leaves the device unbound, so you can retry it any number of times:
```bash
sudo tools/reprobe-trace.sh 0000:xx:00.0
```
Each retry sends mailbox commands to the device again (Identify, Get Supported Logs, ...).

## License
GPL-2.0, the same as the Linux kernel the patch applies to.
