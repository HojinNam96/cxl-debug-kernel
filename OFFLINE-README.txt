cxl-debug-kernel offline bundle (Linux v7.3 + CXL/DAX debug patch)
==================================================================
No network is needed on the target. Everything is in this directory:

  linux-7.3.tar.xz        kernel source, unmodified, from kernel.org
  linux-7.3.tar.sign      kernel.org PGP signature of the uncompressed tar
  cxl-debug-kernel/       patch, Kconfig fragment, scripts, RUNBOOK.md (Korean, step by step)
  SHA256SUMS              checksums of every file above (and of every file in cxl-debug-kernel/)

Put it on a local Linux disk (ext4/xfs, not noexec, no spaces in the path, >= 25 GiB free).
Extract and build as a normal user; only cxl-collect.sh, reprobe-trace.sh and make install need sudo.

  sha256sum -c --quiet SHA256SUMS && echo OK    # transfer intact?
  cd cxl-debug-kernel
  tools/check-build-deps.sh                     # can this host build/install? (lists missing packages)
  nohup ./setup.sh --build > setup.log 2>&1 &   # unpacks ../linux-7.3.tar.xz into ./linux-7.3, builds
  then follow RUNBOOK.md from section D.

Two things stop the boot of the new kernel if ignored (RUNBOOK.md section F):
  - Secure Boot must be off (mokutil --sb-state), or the kernel must be signed.
  - 'make install' makes the new kernel the DEFAULT on Ubuntu (and on RHEL with UPDATEDEFAULT=yes):
    pin the current kernel as default first, then boot the debug kernel once.
