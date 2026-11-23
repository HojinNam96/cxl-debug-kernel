# cxl-debug-kernel

A Linux **v7.3** (mainline tag from torvalds/linux) debug build for finding out why a CXL Type 3 memory device does not register (no `memN`, no region, no `daxX.Y`). With it, every failure in the CXL/DAX stack is printed in `dmesg`, and you do not have to set up dynamic debug by hand.

This repository holds only the patch, a Kconfig fragment, boot parameters and helper scripts. `setup.sh` fetches the kernel source from kernel.org.

```bash
git clone <this repo> && cd cxl-debug-kernel
./setup.sh                      # clone v7.3 from torvalds/linux, apply patch, build .config from /boot/config-$(uname -r)
cd linux-7.3 && make -j"$(nproc)"
sudo make modules_install && sudo make install
# add cmdline.txt parameters to the kernel command line, reboot into 7.3.0-cxldbg
sudo tools/cxl-collect.sh --bdf 0000:xx:00.0       # BIOS + OS state, triage verdict, one tar.gz
```
See `RUNBOOK.md` for the full one-session sequence.

## Why kernel parameters alone are not enough

Turning on every dynamic-debug site still leaves exits in `cxl_pci_probe()` that print nothing at any level:
- No Register Locator DVSEC: `-ENXIO` (`drivers/cxl/core/regs.c:317`).
- No CXL Device Registers block (Block ID 03h): `-ENODEV` (`regs.c:345`).

The driver core reports `-ENXIO` and `-ENODEV` only at debug level (`drivers/base/dd.c:636-640`). Several other exits come after `devm_cxl_add_classdev()`, so the `memN` that was just created is devm-removed again and leaves no trace.

## Contents

| file | what it does |
|---|---|
| `patches/0001-cxl-dax-debug-output.patch` | Adds `-DDEBUG` to `drivers/cxl` (+`core/`) and `drivers/dax` (+`hmem/`), so every `dev_dbg`/`pr_debug` there is enabled by default (`include/linux/dynamic_debug.h:48`). In `cxl_pci_probe()`, every early return logs `cxl_pci_probe: <step> failed: <rc> (<errno>)` at KERN_ERR, and success logs `cxl_pci_probe: done, memN registered`. |
| `config/cxl-debug.config` | The Kconfig fragment. The CXL/DAX stack is built as modules, like distros do, including `CXL_REGION` and `CXL_ATL` (the AMD PRM address translation). It also turns on `DEBUG_DRIVER`, `PCI_DEBUG`, `DYNAMIC_DEBUG`, `FUNCTION_GRAPH_RETVAL`, kprobe/BPF events, a 32 MB log buffer and `IKCONFIG_PROC`. |
| `cmdline.txt` | Boot parameters: `log_buf_len=64M initcall_debug efi=debug`, plus optional ones and a per-module `dyndbg` fallback for kernels built without the patch. |
| `setup.sh` | Clones v7.3 from torvalds/linux (shallow; `--stable v7.3.N` takes a stable point release from gregkh/linux instead), applies the patch and merges the fragment onto your base config. It then runs `olddefconfig` and **fails if any fragment option was dropped**. It also clears the distro signing-cert settings and sets `LOCALVERSION=-cxldbg`. |
| `RUNBOOK.md` | Step-by-step plan for one session on the target (Korean): build in the background, collect on the distro kernel, re-probe without reboot, one-shot boot of the debug kernel, collect again, compare with a working device. |
| `tools/cxl-collect.sh` | Read-only collector, run as root: BIOS version, ACPI CEDT/SRAT/HMAT (raw + iasl), ACPI0016/0017, `/sys/firmware/memmap`, `/proc/iomem`, `lspci -vvv -xxxx` of every class-0502 function and its upstream ports, all `/sys/bus/cxl` and dax attributes, NUMA, modules, dmesg/journal and a grep summary. Runs `cxl_triage.py` and packs everything into one tar.gz. `--enable-dyndbg` turns on dev_dbg for loaded CXL/DAX modules. |
| `tools/cxl_triage.py` | Read-only ladder (DEVICE / BIOS / KERNEL / BYDESIGN) that prints the first failing stage between the PCI function and `/dev/daxX.Y`, with its owner. Tested on synthetic sysfs trees only. |
| `tools/reprobe-trace.sh` | Retries the probe of a device that currently has **no driver bound**, using `function_graph` with return values limited to `cxl_pci_probe`. Saves the trace, the bind errno and the dmesg delta. It never unbinds anything. |

Tested: the fragment merged onto `x86_64_defconfig` and survived `olddefconfig` with every option intact, and `drivers/cxl` and `drivers/dax` compiled without warnings with the patch applied. Not tested on CXL hardware yet.

## Requirements and notes
- Build dependencies (Debian/Ubuntu): `build-essential flex bison bc libelf-dev libssl-dev dwarves`.
- **Secure Boot:** turn it off on the test machine, or sign the kernel. An unsigned kernel is refused, and lockdown blocks tracefs and kprobes.
- On a remote machine, boot it once with `grub-reboot "<menu entry for 7.3.0-cxldbg>"`. The next reboot goes back to the default kernel.
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
