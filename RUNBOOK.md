# RUNBOOK: 한 번에 끝내는 순서 (CXL 장치 미등록 디버깅)

목표: DUT가 `memN` / region / `daxX.Y`까지 못 가는 **첫 번째 끊긴 지점**과 그 책임 주체(DEVICE / BIOS / KERNEL)를 하루에 확정한다.

전체 흐름 (빌드는 오래 걸리니 맨 먼저 백그라운드로 돌린다):

```
0. 준비 (5분)          clone, 빌드 의존성, Secure Boot, BDF 확인
1. 빌드 시작 (백그라운드) ./setup.sh --build   ← 2,3 하는 동안 돈다
2. 현재 커널에서 수집    tools/cxl-collect.sh   ← BIOS 증거는 커널과 무관하게 여기서 확보
3. 재부팅 없이 재프로브  tools/reprobe-trace.sh ← DUT에 드라이버가 안 붙어 있을 때만
4. 디버그 커널 1회 부팅  make install + grub-reboot
5. 디버그 커널에서 수집  tools/cxl-collect.sh --tag cxldbg, 정상 장치 비교
6. 결과 전달            tar.gz 두 개 + SUMMARY.txt
```

---

## 0. 준비

```bash
git clone https://github.com/HojinNam96/cxl-debug-kernel.git && cd cxl-debug-kernel

# 빌드 의존성
sudo apt install -y build-essential flex bison bc libelf-dev libssl-dev dwarves git pciutils acpica-tools   # Ubuntu/Debian
sudo dnf install -y gcc make flex bison bc elfutils-libelf-devel openssl-devel dwarves git pciutils acpica-tools perl  # RHEL/Fedora
# 있으면 좋음: ndctl(cxl, daxctl 명령), numactl, dmidecode

mokutil --sb-state            # "SecureBoot enabled"면 자체 빌드 커널이 부팅 거부됨 → BIOS에서 끄거나 서명 필요
lspci -nn | grep -i '0502'    # CXL 메모리 장치 (class 0502). DUT와 정상 장치의 BDF를 메모
DUT=0000:xx:00.0              # ← 실제 값
GOOD=0000:yy:00.0             # ← region이 잘 생기는 기존 장치 (비교군)
```

## 1. 빌드 시작 (백그라운드)

```bash
nohup ./setup.sh --build > build.log 2>&1 &     # 또는 tmux 안에서 ./setup.sh --build
tail -f build.log                               # 끝나면 ">> built." 출력
```
- 현재 부팅된 배포판 커널의 `/boot/config-$(uname -r)`를 바탕으로 디버그 옵션을 합친다. 옵션이 하나라도 빠지면 `DROPPED:` 를 찍고 멈춘다.
- 결과 커널 이름: `7.3.0-cxldbg`.

## 2. 현재 커널에서 수집 (읽기 전용)

```bash
sudo tools/cxl-collect.sh --bdf $DUT --enable-dyndbg --tag distro
```
- 화면에 `SUMMARY`가 나오고 `cxl-collect-<kernel>-distro-<시각>.tar.gz`가 생긴다.
- 수집 내용:
  - **BIOS 레벨**: BIOS 버전(dmidecode), ACPI `CEDT/SRAT/HMAT` 원본(+iasl 디스어셈블), ACPI0017/ACPI0016 객체, `/sys/firmware/memmap`(Soft Reserved), `/proc/iomem`, dmesg의 e820/EFI SP 줄
  - **OS 레벨**: DUT와 상위 root port까지 `lspci -vvv -xxxx`, `/sys/bus/cxl` 전 객체 속성, dax/NUMA/lsmem, 모듈/파라미터, deferred probe, dmesg 요약
  - **판정**: `TRIAGE.txt`(cxl_triage.py) — 단계별 ok/XX 와 `VERDICT`(첫 실패 단계 + owner)
- `--enable-dyndbg`는 이미 로드된 cxl/dax 모듈의 dev_dbg만 켠다 (이후 dmesg가 자세해짐). 부팅 때 지나간 메시지는 안 돌아온다 → 그래서 4단계가 필요.

### SUMMARY 읽는 법 (첫 번째로 해당하는 줄이 답)

| 보이는 것 | 의미 | 책임 |
|---|---|---|
| `ACPI tables present`에 CEDT 없음, ACPI0017 = 0 | BIOS가 CXL을 OS에 안 넘김 (BIOS CXL 설정 off) | BIOS |
| DUT `class` ≠ `0x050210` | cxl_pci가 매칭 자체를 안 함 | DEVICE (config space) |
| DUT `driver=NONE` | cxl_pci 프로브 실패 → **3단계**에서 errno 확인 | DEVICE 또는 KERNEL |
| `driver=cxl_pci`인데 `memdev=NONE` | memN 생성 후 devm 제거된 경우 → 4단계 패치 로그 필요 | 단계별 |
| memN 있음, region 없음, DUT HPA가 memmap Soft Reserved / CFMWS에 없음 | BIOS가 DUT HDM decoder를 프로그램하지 않음 (자동 region 대상 아님) | BIOS (또는 설계상 수동 `cxl create-region`) |
| TRIAGE `VERDICT` | 위를 자동으로 판정한 결과. `owner`와 `next`를 그대로 따른다 | |

## 3. 재부팅 없이 재프로브 (DUT에 드라이버가 안 붙어 있을 때)

```bash
sudo modprobe cxl_pci                 # 이미 로드돼 있으면 무시됨
echo 'module cxl_pci +pmf'  | sudo tee /proc/dynamic_debug/control
echo 'module cxl_core +pmf' | sudo tee /proc/dynamic_debug/control
sudo tools/reprobe-trace.sh $DUT      # bind errno + function_graph 트레이스 + dmesg 증분 저장
```
- 결과 디렉터리의 `bind-result.txt`가 errno, `trace.txt`가 `cxl_pci_probe` 안에서 **어느 함수가 무슨 값을 리턴했는지**.
- 배포판 커널은 `funcgraph-retval`이 없을 수 있다 (경고만 나옴). 그래도 errno와 dyndbg 줄은 남는다.
- DUT에 mailbox 명령(Identify 등)이 다시 나간다. 프로토콜 분석기에 보일 수 있음. 정상 장치는 건드리지 않는다 (unbind 안 함).
- 여기서 원인이 확정되면 4단계는 생략 가능.

## 4. 디버그 커널 설치 + 1회 부팅

```bash
cd linux-7.3
sudo make modules_install && sudo make install     # initramfs + GRUB 항목 생성, 기존 커널은 그대로
```
부팅 파라미터 `log_buf_len=64M initcall_debug efi=debug`를 **디버그 커널에만** 붙이고 1회만 부팅:

```bash
# RHEL/Fedora (grubby)
sudo grubby --update-kernel=/boot/vmlinuz-7.3.0-cxldbg --args="log_buf_len=64M initcall_debug efi=debug"
sudo grub2-reboot "$(sudo grubby --info=/boot/vmlinuz-7.3.0-cxldbg | sed -n 's/^title="\(.*\)"/\1/p')"
sudo reboot

# Ubuntu/Debian
grep -E "menuentry '.*7.3.0-cxldbg'" /boot/grub/grub.cfg | head -2      # 정확한 메뉴 이름 확인
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 7.3.0-cxldbg"
sudo reboot
#  Ubuntu에서 파라미터는: BMC 콘솔의 GRUB 메뉴에서 'e'로 linux 줄 끝에 추가 (1회성),
#  또는 /etc/default/grub GRUB_CMDLINE_LINUX에 추가 후 update-grub (모든 커널에 적용되지만 무해)
```
- `grub-reboot`/`grub2-reboot`은 다음 1회만 그 커널로 부팅. 문제가 생겨도 재부팅하면 기본 커널로 돌아온다.
- 원격이면 BMC(IPMI/Redfish) 콘솔을 열어 두고 부팅.

## 5. 디버그 커널에서 수집 + 비교군 확인

```bash
uname -r                 # 7.3.0-cxldbg 여야 함
cat /proc/cmdline        # initcall_debug 포함 확인
cd cxl-debug-kernel
sudo tools/cxl-collect.sh --bdf $DUT --tag cxldbg
grep -E "cxl_pci_probe" cxl-collect-*-cxldbg-*/log/dmesg.txt          # DUT: "<step> failed: <rc>" 또는 "done, memN registered"
grep -E "probe of .* returned -" cxl-collect-*-cxldbg-*/log/dmesg.txt  # 어떤 객체의 프로브가 어떤 errno로 실패했는지
```
- **비교군**: SUMMARY의 `cxl objects`에 GOOD 장치의 `memN`, `regionN`, `daxX.Y`가 여전히 있어야 한다. 없으면 커널 쪽 차이부터 의심 (배포판 커널 수집본과 diff).
- 실패 단계별 의미는 `README.md`의 "First failing cxl_pci_probe step" 표.
- DUT에 드라이버가 안 붙었으면 여기서도 `sudo tools/reprobe-trace.sh $DUT` (이 커널에는 funcgraph-retval 있음).

## 6. 결과 전달

```bash
ls cxl-collect-*.tar.gz reprobe-*/      # distro 수집본, cxldbg 수집본, reprobe 결과
```
- 두 수집본의 `SUMMARY.txt`와 `TRIAGE.txt`의 VERDICT 부분을 먼저 공유하면 바로 판정 가능. 전체 tar에는 ACPI 테이블과 config space 원본이 들어 있다.
- tar에는 서버 정보(BIOS 버전, 메모리 맵, PCI 트리)가 들어 있으니 외부 공유 시 주의.

## 롤백
- 기본 커널로: 그냥 재부팅 (grub-reboot은 1회성).
- 디버그 커널 삭제: `sudo rm /boot/*7.3.0-cxldbg* && sudo rm -rf /lib/modules/7.3.0-cxldbg && sudo update-grub` (RHEL: `sudo grubby --remove-kernel=/boot/vmlinuz-7.3.0-cxldbg`).
