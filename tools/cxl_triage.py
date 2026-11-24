#!/usr/bin/env python3
"""cxl_triage.py - find out WHERE a CXL Type 3 memory expander stops on its way to device-dax.

    sudo python3 cxl_triage.py [--bdf 0000:xx:yy.z] [--no-mmio]

Run on the target with Linux already booted. READ-ONLY: it reads PCI config space, ACPI tables,
/proc/iomem, /sys/firmware/memmap, sysfs, dmesg and (unless --no-mmio) side-effect-free MMIO
status/decoder registers. It never writes a register, never binds/unbinds, never sends mailbox commands.

It walks a ladder of stages from the device up to /dev/daxX.Y. The FIRST stage that fails is where the
chain breaks, and each stage is tagged with who owns it:
  DEVICE  the CXL device itself (DVSEC Memory_Info_Valid/Memory_Active, Media Status, mailbox)
  BIOS    platform firmware (CEDT CHBS/CFMWS, ACPI0017/ACPI0016, HDM decoder commit, EFI_MEMORY_SP)
  KERNEL  Linux CXL/DAX drivers and kernel config
  BYDESIGN  not a failure: the configuration simply never produces a device-dax

Spec references are CXL 3.2. Kernel behaviour was checked against Linux v6.8, v6.12 and v7.3 sources.
"""
import argparse, ctypes, ctypes.util, glob, gzip, mmap, os, re, struct, subprocess, sys

ROOT = "/"  # overridable for testing (--root)
def P(path):
    return os.path.join(ROOT, path.lstrip("/"))

# ----------------------------------------------------------------------------- small helpers
def rd(path, default=None):
    try:
        with open(P(path)) as f:
            return f.read().strip()
    except Exception:
        return default
def rdb(path):
    try:
        with open(P(path), "rb") as f:
            return f.read()
    except Exception:
        return None
def exists(path):
    return os.path.lexists(P(path))
def ls(path):
    try:
        return sorted(os.listdir(P(path)))
    except Exception:
        return []
def link_name(path):
    try:
        return os.path.basename(os.readlink(P(path)))
    except Exception:
        return None
def realpath(path):
    return os.path.realpath(P(path))
def run(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return None, "", "not installed"
    except Exception as e:
        return None, "", str(e)
def hx(v):
    return f"0x{v:x}"
def gib(v):
    return f"{v / (1 << 30):.2f} GiB"
def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)
def overlap(a0, a1, b0, b1):  # half-open
    return a0 < b1 and b0 < a1
def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]
def toint(s):
    try:
        return int(s, 0)
    except Exception:
        return None

# ----------------------------------------------------------------------------- ladder bookkeeping
STAGES = []  # dicts: id, title, status (PASS/FAIL/WARN/INFO/SKIP), owner, evidence, meaning, next
def stage(sid, title, status, owner, evidence, meaning="", nxt=""):
    STAGES.append(dict(id=sid, title=title, status=status, owner=owner, evidence=evidence, meaning=meaning, next=nxt))
    mark = {"PASS": "ok ", "FAIL": "XX ", "WARN": "!! ", "INFO": "-- ", "SKIP": ".. "}[status]
    print(f"  [{mark}] {sid} {title}: {evidence}")
    if status in ("FAIL", "WARN", "INFO") and meaning:
        print(f"         => [{owner}] {meaning}")

# ----------------------------------------------------------------------------- PCI config / DVSEC (CXL 3.2 §8.1.3, §8.1.9)
CXL_VID = 0x1E98
MEDIA_STATUS = {0: "Not Ready", 1: "Ready", 2: "Error", 3: "Disabled"}
TIMEOUT = {0: "1 s", 1: "4 s", 2: "16 s", 3: "64 s", 4: "256 s"}
REGBLK = {0: "empty", 1: "Component", 2: "BAR Virt ACL", 3: "CXL Device", 4: "CPMU", 5: "CHMU", 0xFF: "Vendor"}
DEC_COUNT = {0: 1, 1: 2, 2: 4, 3: 6, 4: 8, 5: 10, 6: 12, 7: 14, 8: 16, 9: 20, 0xA: 24, 0xB: 28, 0xC: 32}
IG = {i: 256 << i for i in range(7)}
IW = {0: 1, 1: 2, 2: 4, 3: 8, 4: 16, 8: 3, 9: 6, 0xA: 12}

def find_dvsecs(cfg):
    out, off, seen = [], 0x100, set()
    while off and off < len(cfg) - 4 and off not in seen:
        seen.add(off)
        hdr = u32(cfg, off)
        if hdr in (0, 0xFFFFFFFF):
            break
        if hdr & 0xFFFF == 0x0023:
            h1 = u32(cfg, off + 4)
            if h1 & 0xFFFF == CXL_VID:
                out.append((off, u16(cfg, off + 8), bits(h1, 19, 16), bits(h1, 31, 20)))
        off = bits(hdr, 31, 20) & ~3
    return out

def decode_device_dvsec(cfg, off):
    d = {}
    cap, ctl, lock = u16(cfg, off + 0x0A), u16(cfg, off + 0x0C), u16(cfg, off + 0x14)
    d["Cache_Capable"], d["IO_Capable"], d["Mem_Capable"], d["Mem_HwInit_Mode"] = cap & 1, (cap >> 1) & 1, (cap >> 2) & 1, (cap >> 3) & 1
    d["HDM_Count"] = bits(cap, 5, 4)
    d["Cache_Enable"], d["IO_Enable"], d["Mem_Enable"] = ctl & 1, (ctl >> 1) & 1, (ctl >> 2) & 1
    d["CONFIG_LOCK"] = lock & 1
    d["ranges"] = []
    for i in range(2):
        b = off + 0x18 + 0x10 * i
        szh, szl, bh, bl = u32(cfg, b), u32(cfg, b + 4), u32(cfg, b + 8), u32(cfg, b + 0xC)
        d["ranges"].append({
            "n": i + 1, "size": (szh << 32) | (szl & 0xF0000000), "base": (bh << 32) | (bl & 0xF0000000),
            "Memory_Info_Valid": szl & 1, "Memory_Active": (szl >> 1) & 1, "Memory_Active_Degraded": (szl >> 16) & 1,
            "Media_Type": bits(szl, 4, 2), "Memory_Class": bits(szl, 7, 5),
            "Memory_Active_Timeout": TIMEOUT.get(bits(szl, 15, 13), f"rsvd({bits(szl, 15, 13)})"),
        })
    return d

def decode_reglocator(cfg, off, length):
    blocks = []
    for e in range((length - 0x0C) // 8):
        lo, hi = u32(cfg, off + 0x0C + 8 * e), u32(cfg, off + 0x10 + 8 * e)
        bid = bits(lo, 15, 8)
        if bid:
            blocks.append({"bir": lo & 7, "id": bid, "name": REGBLK.get(bid, hx(bid)), "offset": (hi << 32) | (lo & 0xFFFF0000)})
    return blocks

# ----------------------------------------------------------------------------- MMIO: read-only mmap of sysfs resourceN, exact-width loads
libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
PROT_READ, MAP_SHARED = 1, 1

class MMIO:
    def __init__(self, bdf, bar, offset, length):
        path = P(f"/sys/bus/pci/devices/{bdf}/resource{bar}")
        self.fd = os.open(path, os.O_RDONLY | getattr(os, "O_SYNC", 0))
        pg = mmap.PAGESIZE
        delta = offset % pg
        a = libc.mmap(None, length + delta, PROT_READ, MAP_SHARED, self.fd, offset - delta)
        if a in (None, ctypes.c_void_p(-1).value):
            e = ctypes.get_errno()
            os.close(self.fd)
            raise OSError(e, f"mmap {path}: {os.strerror(e)}")
        self.base = a + delta
    def r32(self, off):  # single 32-bit load; CXL 3.2 §8.2.3 forbids partial reads of component registers
        return ctypes.c_uint32.from_address(self.base + off).value
    def r64(self, off):
        return ctypes.c_uint64.from_address(self.base + off).value

def read_hdm(bdf, blk):
    """component block -> CXL.cachemem primary range at +1000h (Table 8-21) -> HDM Decoder Capability ID 0005h (§8.2.4.20)"""
    m = MMIO(bdf, blk["bir"], blk["offset"], 0x10000)
    cm = 0x1000
    hdr = m.r32(cm)
    if hdr & 0xFFFF != 0x0001:
        raise RuntimeError(f"CXL_Capability_Header ID={hx(hdr & 0xFFFF)}, expected 0001h (§8.2.4.1)")
    hdm = None
    for i in range(1, bits(hdr, 31, 24) + 1):
        h = m.r32(cm + 4 * i)
        if h & 0xFFFF == 0x0005:
            hdm = cm + bits(h, 31, 20)
    if hdm is None:
        return {"present": False}
    cap, gctl = m.r32(hdm), m.r32(hdm + 4)
    decs = []
    for i in range(DEC_COUNT.get(cap & 0xF, 0)):
        o = hdm + 0x20 * i
        ctl = m.r32(o + 0x20)
        decs.append({
            "n": i,
            "base": (m.r32(o + 0x14) << 32) | (m.r32(o + 0x10) & 0xF0000000),
            "size": (m.r32(o + 0x1C) << 32) | (m.r32(o + 0x18) & 0xF0000000),
            "dpa_skip": (m.r32(o + 0x28) << 32) | (m.r32(o + 0x24) & 0xF0000000),
            "IG": IG.get(ctl & 0xF, f"rsvd{ctl & 0xF}"), "IW": IW.get(bits(ctl, 7, 4), f"rsvd{bits(ctl, 7, 4)}"),
            "LockOnCommit": (ctl >> 8) & 1, "Commit": (ctl >> 9) & 1, "Committed": (ctl >> 10) & 1,
            "ErrorNotCommitted": (ctl >> 11) & 1, "TargetRangeType": "HDM-H" if (ctl >> 12) & 1 else "HDM-D/DB",
        })
    return {"present": True, "count": len(decs), "HDM_Decoder_Enable": (gctl >> 1) & 1, "decoders": decs}

def read_memdev_status(bdf, blk):
    """device block: capabilities array (§8.2.9.1) -> Memory Device Status, cap ID 4000h (§8.2.9.5.1.1)"""
    m = MMIO(bdf, blk["bir"], blk["offset"], 0x1000)
    caps = {}
    for i in range(1, min(m.r32(4) & 0xFFFF, 64) + 1):
        caps[m.r32(0x10 * i) & 0xFFFF] = m.r32(0x10 * i + 4)
    if 0x4000 not in caps:
        return {"present": False}
    off = caps[0x4000]
    if off + 8 > 0x1000:
        m = MMIO(bdf, blk["bir"], blk["offset"], off + 8)
    v = m.r64(off)
    return {"present": True, "Device_Fatal": v & 1, "FW_Halt": (v >> 1) & 1, "Media_Status": MEDIA_STATUS[bits(v, 3, 2)],
            "Mailbox_Interfaces_Ready": (v >> 4) & 1, "Reset_Needed": bits(v, 7, 5)}

# ----------------------------------------------------------------------------- ACPI tables (CXL 3.2 §9.18.1)
CFMWS_BITS = ["DeviceCoherent", "HostOnlyCoherent", "Volatile", "Persistent", "FixedConfig", "BI"]
def parse_cedt(t):
    chbs, cfmws, off = [], [], 36
    while off + 4 <= len(t):
        typ, ln = t[off], u16(t, off + 2)
        if ln < 4:
            break
        if typ == 0:
            chbs.append({"uid": u32(t, off + 4), "ver": u32(t, off + 8), "base": u64(t, off + 0x10), "len": u64(t, off + 0x18)})
        elif typ == 1:
            eniw = t[off + 0x18]
            niw = (1 << eniw) if eniw < 8 else 3 * (1 << (eniw - 8))
            r = u16(t, off + 0x20)
            cfmws.append({"base": u64(t, off + 8), "size": u64(t, off + 0x10), "niw": niw, "arith": t[off + 0x19],
                          "hbig": 256 << u32(t, off + 0x1C), "restrict": r, "flags": [n for b, n in enumerate(CFMWS_BITS) if r >> b & 1],
                          "qtg": u16(t, off + 0x22), "targets": [u32(t, off + 0x24 + 4 * k) for k in range(niw) if off + 0x28 + 4 * k <= len(t)]})
        off += ln
    return {"chbs": chbs, "cfmws": cfmws}

def parse_srat_mem(t):
    out, off = [], 48
    while off + 2 <= len(t):
        typ, ln = t[off], t[off + 1]
        if ln < 2:
            break
        if typ == 1 and ln >= 40:
            fl = u32(t, off + 28)
            out.append({"pxm": u32(t, off + 2), "base": u64(t, off + 8), "len": u64(t, off + 16), "enabled": fl & 1, "hotplug": (fl >> 1) & 1})
        off += ln
    return out

def parse_iomem():
    out = []
    for line in (rd("/proc/iomem") or "").splitlines():
        m = re.match(r"^(\s*)([0-9a-f]+)-([0-9a-f]+) : (.*)$", line)
        if m:
            out.append((len(m.group(1)) // 2, int(m.group(2), 16), int(m.group(3), 16) + 1, m.group(4)))
    return out

# default-loglevel kernel messages that matter here (verified in v6.8/v6.12/v7.3 sources)
DMESG_KEYS = re.compile("|".join([
    r"host supports CXL", r"No CHBS found", r"CHBS invalid", r"CHBS version mismatch", r"unable to retrieve _UID",
    r"CFMWS", r"Failed to add decode range", r"Invalid zero length", r"Expanded resource CXL Window",
    r"Device DVSEC not present", r"No component registers", r"registers not found", r"Media not active",
    r"timeout awaiting", r"Timeout awaiting memory range", r"Mailbox is too small", r"Failed to query partition",
    r"CXL port topology", r"failed probe", r"disabled, failed to enumerate CXL\.mem", r"no parent for dport",
    r"HDM decoder", r"Invalid resource range", r"Committed out of order", r"Committed with zero size",
    r"Invalid interleave", r"invalid committed configuration size", r"Failed to reserve DPA range",
    r"Range register decodes outside", r"does not map any partition", r"no CXL window for range",
    r"failed assign region", r"autodiscovery interrupted", r"cannot insert resource", r"failed to find decoder mapping",
    r"mismatched CXL topologies", r"unable to add decoder to autodetected region", r"no more target slots",
    r"expected iw:", r"got iw:", r"failed to attach", r"failed to activate", r"failed to enable, range",
    r"dax_region resource conflict", r"rejecting DAX region", r"could not reserve region", r"memory add failed",
    r"DAX region truncated", r"probe with driver (cxl|dax|kmem|device_dax)\S* failed with error",
    r"(cxl|dax)\S*: probe of \S+ failed with error", r"BIOS-e820.*soft reserved", r"ACPI: (CEDT|SRAT|HMAT) ",
    r"efi: mem.*\|SP", r"Lockdown:",
]))

# ----------------------------------------------------------------------------- main
def main():
    global ROOT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bdf", help="limit to one PCI function, e.g. 0000:3a:00.0")
    ap.add_argument("--no-mmio", action="store_true", help="skip MMIO register reads")
    ap.add_argument("--root", default="/", help=argparse.SUPPRESS)
    ap.add_argument("--dmesg-file", help=argparse.SUPPRESS)
    a = ap.parse_args()
    ROOT = a.root
    if os.geteuid() != 0 and ROOT == "/":
        print("!! not root: extended config space (DVSEC), ACPI tables, /proc/iomem addresses and dmesg need root. Results will be wrong/incomplete.\n")

    rel = os.uname().release
    km = re.match(r"(\d+)\.(\d+)", rel)
    kver = (int(km.group(1)), int(km.group(2))) if km else (0, 0)
    cmdline = rd("/proc/cmdline") or ""
    if a.dmesg_file:
        dmesg = open(a.dmesg_file).read()
    else:
        rc, out, _ = run(["dmesg"])
        dmesg = out if rc == 0 else ""

    # ============================================================== 0. kernel build / boot configuration
    print("=" * 110)
    print(f"[0] kernel {rel}   cmdline: {cmdline}")
    cfgtxt = rd(f"/boot/config-{rel}")
    if cfgtxt is None:
        b = rdb("/proc/config.gz")
        cfgtxt = gzip.decompress(b).decode() if b else ""
    def kc(name):
        m = re.search(rf"^CONFIG_{name}=(\S+)", cfgtxt, re.M)
        return m.group(1) if m else "n"
    names = ["CXL_BUS", "CXL_ACPI", "CXL_PCI", "CXL_MEM", "CXL_PORT", "CXL_REGION", "DEV_DAX", "DEV_DAX_CXL", "DEV_DAX_KMEM",
             "DEV_DAX_HMEM", "EFI_SOFT_RESERVE", "MEMORY_HOTPLUG", "FIRMWARE_MEMMAP", "DYNAMIC_DEBUG"]
    if cfgtxt:
        print("    " + " ".join(f"{n}={kc(n)}" for n in names))
        missing = [n for n in ["CXL_BUS", "CXL_ACPI", "CXL_PCI", "CXL_MEM", "CXL_PORT", "CXL_REGION", "DEV_DAX", "DEV_DAX_CXL"] if kc(n) == "n"]
        stage("K0", "kernel config for CXL region -> device-dax", "FAIL" if missing else "PASS", "KERNEL",
              f"missing: {missing}" if missing else "CXL_* / CXL_REGION / DEV_DAX_CXL present",
              "without CXL_REGION no region is ever auto-assembled; without DEV_DAX_CXL a region never becomes device-dax", "rebuild kernel")
        sr_off = kc("EFI_SOFT_RESERVE") == "n" or "efi=nosoftreserve" in cmdline
        stage("K0b", "EFI_MEMORY_SP honoured as Soft Reserved", "INFO" if sr_off else "PASS", "BYDESIGN",
              "CONFIG_EFI_SOFT_RESERVE=n or efi=nosoftreserve" if sr_off else "CONFIG_EFI_SOFT_RESERVE=y, no efi=nosoftreserve",
              "EFI_MEMORY_SP memory is turned into ordinary System RAM, so no device-dax will appear for it")
    else:
        stage("K0", "kernel config", "SKIP", "KERNEL", "no /boot/config-* and no /proc/config.gz")
    mods = [l.split()[0] for l in (rd("/proc/modules") or "").splitlines() if re.match(r"(cxl|dax|kmem|device_dax)", l)]
    print(f"    loaded modules: {' '.join(mods) or '(none: built-in or not loaded)'}   lockdown: {rd('/sys/kernel/security/lockdown', 'n/a')}")

    # ============================================================== 1. firmware hand-off (independent of CXL drivers)
    print("=" * 110)
    print("[1] firmware hand-off: ACPI CEDT/SRAT, ACPI0017/ACPI0016, memory map")
    cedt_raw = rdb("/sys/firmware/acpi/tables/CEDT")
    cedt = parse_cedt(cedt_raw) if cedt_raw else None
    if cedt is None:
        stage("F1", "ACPI CEDT table", "FAIL", "BIOS", "/sys/firmware/acpi/tables/CEDT missing (or not root)",
              "no CEDT -> cxl_acpi fails with -ENXIO silently; no root decoders, no CXL Window, nothing above can work", "BIOS: enable CXL / CEDT")
    else:
        for c in cedt["chbs"]:
            print(f"    CHBS uid={c['uid']} ver={c['ver']} ({'RCH/CXL1.1' if c['ver'] == 0 else 'CXL2.0+ host bridge'}) CHBCR={hx(c['base'])} len={hx(c['len'])}")
        for i, w in enumerate(cedt["cfmws"]):
            print(f"    CFMWS[{i}] {hx(w['base'])}-{hx(w['base'] + w['size'] - 1)} ({gib(w['size'])}) ways={w['niw']} HBIG={w['hbig']} "
                  f"restrict={hx(w['restrict'])}={w['flags']} qtg={w['qtg']} targets(_UID)={w['targets']}")
        stage("F1", "CEDT CHBS", "PASS" if cedt["chbs"] else "FAIL", "BIOS", f"{len(cedt['chbs'])} CHBS",
              "no CHBS -> every ACPI0016 host bridge logs 'No CHBS found for Host Bridge' and is skipped")
        stage("F2", "CEDT CFMWS (HPA windows)", "PASS" if cedt["cfmws"] else "FAIL", "BIOS", f"{len(cedt['cfmws'])} CFMWS",
              "no CFMWS -> root0 has no decoder0.*, nothing can be mapped; cxl_acpi logs nothing for this case")
        t3ram = [i for i, w in enumerate(cedt["cfmws"]) if "HostOnlyCoherent" in w["flags"] and "Volatile" in w["flags"]]
        if cedt["cfmws"]:
            stage("F2b", "CFMWS usable for Type 3 volatile", "PASS" if t3ram else "WARN", "BIOS", f"windows with HostOnlyCoherent+Volatile: {t3ram}",
                  "manual 'cxl create-region -t ram' needs a window with bit1+bit2 (create_ram_region); BIOS-committed auto-assembly is not gated by it")
    a17 = [d for d in ls("/sys/bus/acpi/devices") if d.startswith("ACPI0017")]
    a16 = [d for d in ls("/sys/bus/acpi/devices") if d.startswith("ACPI0016")]
    stage("F3", "ACPI0017 (CXL root object) / ACPI0016 (CXL host bridges)", "PASS" if a17 and a16 else "FAIL", "BIOS",
          f"ACPI0017={a17 or 'none'} ACPI0016={a16 or 'none'}",
          "cxl_acpi binds only to _HID ACPI0017 and treats a host bridge as CXL only if its primary _HID is ACPI0016 (a _CID match is ignored)")
    srat_raw = rdb("/sys/firmware/acpi/tables/SRAT")
    srat = parse_srat_mem(srat_raw) if srat_raw else []
    fwmap = []
    for d_ in ls("/sys/firmware/memmap"):
        s, e = toint(rd(f"/sys/firmware/memmap/{d_}/start") or ""), toint(rd(f"/sys/firmware/memmap/{d_}/end") or "")
        if s is not None and e is not None:
            fwmap.append((s, e + 1, rd(f"/sys/firmware/memmap/{d_}/type")))
    sr = [(s, e) for s, e, t in fwmap if t == "Soft Reserved"]
    print(f"    /sys/firmware/memmap Soft Reserved: {[f'{hx(s)}-{hx(e - 1)}' for s, e in sr] or 'none'}")
    iomem = parse_iomem()
    root_ok = any(s for _, s, _, _ in iomem)
    print("    /proc/iomem (CXL-relevant):" + ("" if root_ok else "  (addresses zeroed: not root)"))
    for lvl, s, e, name in iomem:
        if re.search(r"CXL|Soft Reserved|region\d|dax|kmem|hmem", name):
            print(f"      {'  ' * lvl}{hx(s)}-{hx(e - 1)} : {name}")
    if kver >= (7, 0):
        print("    note: kernel >= 7.0 keeps Soft Reserved out of /proc/iomem; /sys/firmware/memmap is the source of truth")

    # ============================================================== 2. PCI device + DVSEC + MMIO
    print("=" * 110)
    print("[2] PCI functions with 'PCIe DVSEC for CXL Devices' (DVSEC ID 0, CXL 3.2 §8.1.3)")
    devs = {}
    for bdf in ls("/sys/bus/pci/devices"):
        if a.bdf and bdf != a.bdf:
            continue
        cfg = rdb(f"/sys/bus/pci/devices/{bdf}/config")
        if not cfg or len(cfg) < 0x200:
            continue
        dv = find_dvsecs(cfg)
        if any(i == 0 for _, i, _, _ in dv):
            devs[bdf] = (cfg, dv)
    if not devs:
        stage("D0", "CXL device function", "FAIL", "DEVICE", "no function with the CXL device DVSEC (or not root)",
              "lspci may list the device, but without the DVSEC (or without root to read extended config) nothing else can be judged")

    for bdf, (cfg, dv) in devs.items():
        print("-" * 110)
        cls = rd(f"/sys/bus/pci/devices/{bdf}/class") or "?"
        drv = link_name(f"/sys/bus/pci/devices/{bdf}/driver")
        d = decode_device_dvsec(cfg, next(o for o, i, _, _ in dv if i == 0))
        blocks = []
        for o, i, rev, ln in dv:
            if i == 8:
                blocks = decode_reglocator(cfg, o, ln)
        print(f"  {bdf} class={cls} driver={drv} DVSECs={[f'ID{i}@{hx(o)}' for o, i, _, _ in dv]}")
        print(f"    CXL Capability: Mem_Capable={d['Mem_Capable']} Mem_HwInit_Mode={d['Mem_HwInit_Mode']} HDM_Count={d['HDM_Count']}  "
              f"Control: Mem_Enable={d['Mem_Enable']}  Lock: CONFIG_LOCK={d['CONFIG_LOCK']}")
        for r in d["ranges"][: max(d["HDM_Count"], 1)]:
            print(f"    Range{r['n']}: size={hx(r['size'])} ({gib(r['size'])}) base={hx(r['base'])} Memory_Info_Valid={r['Memory_Info_Valid']} "
                  f"Memory_Active={r['Memory_Active']} Degraded={r['Memory_Active_Degraded']} timeout={r['Memory_Active_Timeout']}")
        print(f"    Register Locator: {[f'{b['name']}@BAR{b['bir']}+{hx(b['offset'])}' for b in blocks] or 'none'}")
        hdm = mds = None
        mmio_skip = None
        if len(cfg) >= 6 and not (u16(cfg, 4) & 0x2):
            mmio_skip = "PCI Command Memory Space Enable=0 (a read would only produce Unsupported Requests / AER noise)"
        else:
            ps = rd(f"/sys/bus/pci/devices/{bdf}/power_state", "")
            if ps and ps not in ("D0", "unknown"):
                mmio_skip = f"function is in {ps}, not D0"
        if mmio_skip and not a.no_mmio and blocks:
            print(f"    MMIO skipped: {mmio_skip}")
        if not a.no_mmio and not mmio_skip:
            for b in blocks:
                try:
                    if b["id"] == 1:
                        hdm = read_hdm(bdf, b)
                    elif b["id"] == 3:
                        mds = read_memdev_status(bdf, b)
                except Exception as e:
                    print(f"    MMIO {b['name']} block not readable: {e}")
        if mds and mds.get("present"):
            print(f"    Memory Device Status: Media_Status={mds['Media_Status']} Mailbox_Ready={mds['Mailbox_Interfaces_Ready']} "
                  f"Fatal={mds['Device_Fatal']} FW_Halt={mds['FW_Halt']} Reset_Needed={mds['Reset_Needed']}")
        if hdm and hdm.get("present"):
            print(f"    HDM Decoder Capability: {hdm['count']} decoders, HDM_Decoder_Enable={hdm['HDM_Decoder_Enable']}")
            for x in hdm["decoders"]:
                print(f"      HW decoder{x['n']}: base={hx(x['base'])} size={hx(x['size'])} ({gib(x['size'])}) skip={hx(x['dpa_skip'])} IW={x['IW']} IG={x['IG']} "
                      f"Commit={x['Commit']} Committed={x['Committed']} ErrNotCommitted={x['ErrorNotCommitted']} LockOnCommit={x['LockOnCommit']} {x['TargetRangeType']}")

        # ---- device-side stages
        stage("D1", "PCI class 05h/02h/10h (what cxl_pci binds to)", "PASS" if cls.lower() == "0x050210" else "FAIL", "DEVICE",
              f"class={cls}", "cxl_pci only matches class code 050210h; any other class -> no driver, no log")
        stage("D2", "Mem_Capable", "PASS" if d["Mem_Capable"] else "FAIL", "DEVICE", f"Mem_Capable={d['Mem_Capable']}",
              "device does not advertise CXL.mem (§8.1.3.1)")
        r1 = d["ranges"][0]
        ok = r1["Memory_Info_Valid"] and (r1["Memory_Active"] or r1["Memory_Active_Degraded"])
        stage("D3", "DVSEC Range1 Memory_Info_Valid & Memory_Active", "PASS" if ok else "FAIL", "DEVICE",
              f"valid={r1['Memory_Info_Valid']} active={r1['Memory_Active']} degraded={r1['Memory_Active_Degraded']} size={gib(r1['size'])}",
              "device memory not initialized (§8.1.3.8.2). Linux cxl_pci then logs 'Media not active' and cxl_mem fails with -16 (EBUSY)")
        if mds and mds.get("present"):
            ok = mds["Media_Status"] == "Ready" and mds["Mailbox_Interfaces_Ready"] and not mds["Device_Fatal"] and not mds["FW_Halt"]
            stage("D4", "Memory Device Status (Media Ready, Mailbox Ready)", "PASS" if ok else "FAIL", "DEVICE",
                  f"media={mds['Media_Status']} mbox_ready={mds['Mailbox_Interfaces_Ready']} fatal={mds['Device_Fatal']} fw_halt={mds['FW_Halt']}",
                  "§8.2.9.5.1.1: Linux requires Media Status=Ready; mailbox-not-ready -> 'timeout awaiting mailbox ready'")
        else:
            stage("D4", "Memory Device Status", "SKIP", "DEVICE", "not read (MMIO skipped/unavailable)")

        # ---- firmware programming of this device
        committed = [x for x in (hdm or {}).get("decoders", []) if x["Committed"] and x["size"]]
        errnc = [x["n"] for x in (hdm or {}).get("decoders", []) if x["ErrorNotCommitted"]]
        dvsec_rr = d["Mem_Enable"] and (not hdm or not hdm.get("present") or not hdm["HDM_Decoder_Enable"]) and r1["base"]
        if errnc:
            stage("B1", "endpoint HDM decoder commit", "FAIL", "BIOS", f"Error Not Committed=1 on decoder {errnc}",
                  "decoder programming failed the §8.2.4.20.12 checks (BIOS programming or device bug)")
        elif hdm is None or not hdm.get("present"):
            stage("B1", "endpoint HDM decoder commit", "SKIP", "BIOS", "HDM registers not read; see sysfs stage E3 instead")
        elif committed:
            stage("B1", "endpoint HDM decoder commit", "PASS", "BIOS",
                  f"committed by firmware: {[f'dec{x['n']} {hx(x['base'])}+{gib(x['size'])}' for x in committed]} "
                  "(Linux never commits decoders at probe; only 'cxl create-region' does)")
        elif dvsec_rr:
            stage("B1", "endpoint memory mapping via DVSEC range registers", "PASS", "BIOS",
                  f"HDM decoders not enabled, Mem_Enable=1, DVSEC Range1 base={hx(r1['base'])}: Linux emulates a locked AUTO decoder from it")
        else:
            stage("B1", "endpoint HDM decoder commit", "INFO", "BYDESIGN",
                  "no committed HDM decoder and no DVSEC range mapping",
                  "firmware did NOT map this device's memory (OS-first). Linux never auto-creates a region or device-dax in this case; "
                  "it is not a failure. Create one: cxl create-region -m -d <root decoder> -t ram -w 1 <memN>")
        ranges = [(f"HW decoder{x['n']}", x["base"], x["base"] + x["size"]) for x in committed]
        if dvsec_rr and not committed:
            ranges.append(("DVSEC Range1", r1["base"], r1["base"] + r1["size"]))
        for what, s, e in ranges:
            win = [i for i, w in enumerate((cedt or {}).get("cfmws", [])) if s >= w["base"] and e <= w["base"] + w["size"]]
            mt = sorted({t for fs, fe, t in fwmap if overlap(s, e, fs, fe)})
            io = sorted({n for _, x0, x1, n in iomem if x0 and overlap(s, e, x0, x1)})
            px = [m["pxm"] for m in srat if overlap(s, e, m["base"], m["base"] + m["len"])]
            print(f"    {what} {hx(s)}-{hx(e - 1)}: CFMWS={win or 'NONE'} memmap={mt or 'none'} SRAT_PXM={px or 'none'} iomem={io or 'none'}")
            if cedt is not None:
                stage("B2", f"{what} inside a CFMWS window", "PASS" if win else "FAIL", "BIOS", f"windows={win}",
                      "BIOS-committed range outside every CFMWS -> Linux logs 'no CXL window for range' (HDM path) or "
                      "'Range register decodes outside platform defined CXL ranges.' (DVSEC path) and builds no region")
            if "System RAM" in mt or ("System RAM" in io and not any("kmem" in n for n in io)):
                stage("B3", f"{what} memory type handed to the OS", "INFO", "BYDESIGN", f"memmap={mt} iomem={io}",
                      "firmware reported this CXL range as ordinary System RAM (no EFI_MEMORY_SP / Soft Reserved): it is already "
                      "online as normal memory in a NUMA node and NO device-dax is created by design (Linux: region probes, "
                      "sees System RAM, skips dax_region silently). Change the BIOS option (e.g. 'CXL memory as SPM / Soft Reserved')")
            elif "Soft Reserved" in mt:
                stage("B3", f"{what} memory type handed to the OS", "PASS", "BIOS", "Soft Reserved (EFI_MEMORY_SP) -> eligible for device-dax")
            elif fwmap:
                stage("B3", f"{what} memory type handed to the OS", "WARN", "BIOS", f"memmap={mt or 'not listed'}",
                      "range is neither System RAM nor Soft Reserved in the firmware map (not described in e820/EFI map?)")

        # ============================================================== 3. kernel ladder for this device
        print("  kernel objects:")
        stage("K1", "PCI driver bound", "PASS" if drv == "cxl_pci" else "FAIL", "KERNEL", f"driver={drv}",
              "cxl_pci not bound: class mismatch (D1), module missing, or probe failed (silent if -ENXIO/-ENODEV, e.g. missing Register "
              "Locator/Memory Device block or a mailbox command error during probe)",
              f"echo {bdf} > /sys/bus/pci/drivers/cxl_pci/bind  (prints the errno) after enabling dyndbg, see below")
        acpi_bound = exists("/sys/bus/platform/drivers/cxl_acpi/ACPI0017:00")
        roots = [n for n in ls("/sys/bus/cxl/devices") if n.startswith("root")]
        rdec = [n for n in ls("/sys/bus/cxl/devices") if re.match(r"decoder0\.\d+$", n)]
        stage("K2", "cxl_acpi bound, root0 + root decoders", "PASS" if acpi_bound and roots and rdec else "FAIL", "KERNEL",
              f"cxl_acpi bound={acpi_bound} roots={roots} root decoders={rdec} (CFMWS in CEDT={len((cedt or {}).get('cfmws', []))})",
              "if F1-F3 passed but this fails: cxl_acpi not loaded/built, or CFMWS rejected (look for 'CFMWS ...' / 'Failed to add decode range' in dmesg)")
        if cedt and rdec and len(rdec) < len(cedt["cfmws"]):
            stage("K2b", "every CFMWS accepted", "FAIL", "BIOS", f"{len(rdec)} root decoders for {len(cedt['cfmws'])} CFMWS",
                  "some CFMWS failed cxl_acpi validation (alignment / ways / CXIMS); dmesg has the dev_err")
        mems = [n for n in ls("/sys/bus/cxl/devices") if n.startswith("mem") and os.path.basename(os.path.dirname(realpath(f"/sys/bus/cxl/devices/{n}"))) == bdf]
        mem = mems[0] if mems else None
        stage("K3", "memN created by cxl_pci", "PASS" if mem else "FAIL", "KERNEL", f"memdev={mem}",
              "cxl_pci probe did not complete")
        if not mem:
            continue
        mdrv = link_name(f"/sys/bus/cxl/devices/{mem}/driver")
        ram = toint(rd(f"/sys/bus/cxl/devices/{mem}/ram/size") or "") or 0
        fw = rd(f"/sys/bus/cxl/devices/{mem}/firmware_version") or ""
        stage("K4", "device identified (ram/size, firmware_version)", "PASS" if ram and fw else "FAIL", "DEVICE",
              f"ram/size={hx(ram)} firmware_version='{fw}'",
              "Linux saw media not ready (Memory_Active / Media Status) and skipped IDENTIFY, or the device reports 0 volatile capacity")
        stage("K5", "cxl_mem bound to memN", "PASS" if mdrv == "cxl_mem" else "FAIL", "KERNEL", f"driver={mdrv}",
              "cxl_mem failed: -16 = media not ready (D3/D4); 'CXL port topology not found' = no CXL port above the device "
              "(the most common silent case: root port is not under a host bridge that cxl_acpi registered -> check F3/K2)",
              f"echo {mem} > /sys/bus/cxl/drivers/cxl_mem/bind   (shell shows the errno, non-destructive while unbound)")
        eps = [n for n in ls("/sys/bus/cxl/devices") if n.startswith("endpoint") and link_name(f"/sys/bus/cxl/devices/{n}/uport") == mem]
        ep = eps[0] if eps else None
        epdrv = link_name(f"/sys/bus/cxl/devices/{ep}/driver") if ep else None
        stage("K6", "endpoint port enumerated", "PASS" if ep and epdrv == "cxl_port" else "FAIL", "KERNEL",
              f"endpoint={ep} driver={epdrv} decoders_committed={rd(f'/sys/bus/cxl/devices/{ep}/decoders_committed') if ep else None}",
              "endpoint decoder enumeration failed (dmesg: 'HDM decoder registers not found', 'Invalid resource range', "
              "'Failed to reserve DPA range', ... -> '<endpoint> failed probe')")
        if not ep:
            continue
        edecs = [n for n in ls(f"/sys/bus/cxl/devices/{ep}") if re.match(r"decoder\d+\.\d+$", n)]
        regions, bydesign_regions = set(), set()
        for n in edecs:
            p = f"/sys/bus/cxl/devices/{n}"
            at = {k: rd(f"{p}/{k}", "") for k in ("start", "size", "mode", "locked", "dpa_resource", "dpa_size", "region", "interleave_ways")}
            print(f"    {n}: " + " ".join(f"{k}={v}" for k, v in at.items()))
            if at["region"]:
                regions.add(at["region"])
        live = [n for n in edecs if (toint(rd(f"/sys/bus/cxl/devices/{n}/size") or "") or 0) > 0]
        stage("E3", "kernel sees a committed/AUTO endpoint decoder", "PASS" if live else "INFO", "BYDESIGN" if not live else "BIOS",
              f"decoders with size>0: {live}",
              "no committed decoder -> no auto-assembled region; needs 'cxl create-region' (OS-first)")
        if live and not regions:
            stage("K7", "auto-assembled region", "FAIL", "KERNEL",
                  "committed decoder(s) present but region attribute empty",
                  "region auto-assembly failed (CFMWS mismatch -> 'no CXL window for range'; interleave member missing -> silent; "
                  "partition mismatch -> 'does not map any partition'; others are dev_dbg only)")
        for rg in sorted(regions):
            p = f"/sys/bus/cxl/devices/{rg}"
            rdrv = link_name(f"{p}/driver")
            commit = rd(f"{p}/commit")
            print(f"    {rg}: commit={commit} mode={rd(p + '/mode')} resource={rd(p + '/resource')} size={rd(p + '/size')} ways={rd(p + '/interleave_ways')} driver={rdrv}")
            stage("K7", f"{rg} committed and bound to cxl_region", "PASS" if commit == "1" and rdrv == "cxl_region" else "FAIL", "KERNEL",
                  f"commit={commit} driver={rdrv}",
                  "region stuck below COMMIT (e.g. waiting for other interleave members) -> cxl_region refuses it silently ('config state')")
            dr = [n for n in ls(p) if n.startswith("dax_region")]
            rs, rsz = toint(rd(p + "/resource") or ""), toint(rd(p + "/size") or "")
            sysram = False
            if rs is not None and rsz:
                sysram = any(n == "System RAM" and x0 and overlap(rs, rs + rsz, x0, x1) for _, x0, x1, n in iomem) or \
                         any(t == "System RAM" and overlap(rs, rs + rsz, x0, x1) for x0, x1, t in fwmap)
            if not dr and sysram:
                bydesign_regions.add(rg)
                stage("K8", f"{rg} -> dax_region", "INFO", "BYDESIGN", "no dax_region; region range is System RAM",
                      "firmware handed this range to Linux as System RAM, so cxl_region skips dax creation (dev_dbg only). Not a kernel failure.")
                continue
            ddrv = link_name(f"{p}/{dr[0]}/driver") if dr else None
            stage("K8", f"{rg} -> dax_region bound to cxl_dax_region (dax_cxl)", "PASS" if dr and ddrv == "cxl_dax_region" else "FAIL", "KERNEL",
                  f"dax_region={dr or None} driver={ddrv}",
                  "dax_cxl not loaded/built (CONFIG_DEV_DAX_CXL) or its probe failed (e.g. alignment -> -ENOMEM 'probe ... failed with error -12')")
        # dax devices and who created them
        daxs = []
        for n in ls("/sys/bus/dax/devices"):
            rp = realpath(f"/sys/bus/dax/devices/{n}")
            owner = "cxl:" + m.group(0) if (m := re.search(r"region\d+", rp)) else ("hmem:" + m2.group(0) if (m2 := re.search(r"hmem\.\d+", rp)) else "other")
            daxs.append((n, owner, link_name(f"/sys/bus/dax/devices/{n}/driver")))
        print(f"    /sys/bus/dax/devices: {daxs or 'none'}")
        mine = [x for x in daxs if x[1].startswith("cxl:") and x[1][4:] in regions]
        if regions - bydesign_regions:
            stage("K9", "daxX.Y from this device's region", "PASS" if mine else "FAIL", "KERNEL", f"{mine or 'none'}",
                  "dax device not created (see K8). If a dax exists under hmem.N instead, dax_hmem claimed the Soft Reserved range "
                  "(v7.1+ fallback when CXL did not claim it, or a probe-ordering issue on older kernels)")
            for n, owner, ddv in mine:
                print(f"      {n}: driver={ddv} (kmem = hot-plugged as System RAM (kmem); device_dax = /dev/{n} usable as char dev)")

    # ============================================================== 4. logs
    print("=" * 110)
    print("[4] default-loglevel kernel messages that bear on this (dev_dbg ones are not in the buffer unless dyndbg was on)")
    hits = [l.strip() for l in dmesg.splitlines() if DMESG_KEYS.search(l)]
    for l in hits[:200]:
        print("    " + l)
    if not dmesg:
        print("    (dmesg unreadable)")
    elif not hits:
        print("    (none) - note: a fully successful CXL->dax bring-up prints almost nothing either; only 'host supports CXL' is expected")
    if not any("host supports CXL" in l for l in hits) and dmesg:
        print("    no 'host supports CXL' line: cxl_acpi registered no CXL host bridge (or the log buffer wrapped; try journalctl -k -b)")
    dd = rd("/proc/dynamic_debug/control") is not None
    print(f"    dynamic debug control: {'/proc/dynamic_debug/control present' if dd else 'not available (CONFIG_DYNAMIC_DEBUG=n?)'}")

    # ============================================================== 5. verdict
    print("=" * 110)
    print("VERDICT")
    fails = [s for s in STAGES if s["status"] == "FAIL"]
    bydesign = [s for s in STAGES if s["owner"] == "BYDESIGN" and s["status"] == "INFO"]
    if fails:
        f = fails[0]
        print(f"  first failing stage: {f['id']} {f['title']}  -> owner: {f['owner']}")
        print(f"    evidence: {f['evidence']}")
        print(f"    meaning : {f['meaning']}")
        if f["next"]:
            print(f"    next    : {f['next']}")
        for s in fails[1:]:
            print(f"  also failing: {s['id']} {s['title']} [{s['owner']}]")
    for s in bydesign:
        print(f"  by design: {s['id']} {s['title']}: {s['meaning']}")
    if not fails and not bydesign:
        print("  no failing stage found")
    print("""
  To capture the dev_dbg reasons (non-destructive):
    a) runtime, for an object that is NOT bound yet:
         echo 'module cxl_* +pmf' > /proc/dynamic_debug/control
         echo 'module dax* +pmf'  > /proc/dynamic_debug/control
         echo 'file drivers/base/dd.c +p' > /proc/dynamic_debug/control
         echo memN > /sys/bus/cxl/drivers/cxl_mem/bind      # errno is printed by the shell, reasons go to dmesg
    b) full replay of boot-time probing: reboot with
         cxl_core.dyndbg=+pmf cxl_acpi.dyndbg=+pmf cxl_pci.dyndbg=+pmf cxl_mem.dyndbg=+pmf cxl_port.dyndbg=+pmf dax_cxl.dyndbg=+pmf dax_hmem.dyndbg=+pmf efi=debug log_buf_len=16M
  Do NOT unbind cxl_pci / cxl_mem / cxl_port / cxl_acpi of a device whose region is committed: teardown clears COMMIT and
  zeroes Base/Size of BIOS-programmed HDM decoders that are not locked, and the region will not auto-assemble again until reboot.""")

if __name__ == "__main__":
    main()
