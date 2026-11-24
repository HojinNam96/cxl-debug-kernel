# RUNBOOK: 내부망(오프라인) 서버에서 한 번에 끝내기

**목표:** DUT가 `memN` / region / `daxX.Y`까지 가지 못하는 **첫 번째 끊긴 지점**과 그 책임 주체(DEVICE / BIOS / KERNEL)를 하루 안에 확정한다.

**전제:**
- 대상 서버는 인터넷이 안 된다. 인터넷이 되는 PC에서 아래 둘 중 하나를 **파일 1개**로 받아 반입한다. 둘 다 Linux 7.3 커널 소스 전체(96,080개 항목)와 패치, 설정, 스크립트를 담고 있다.
  - **저장소 압축본** `cxl-debug-kernel-main.tar.gz`: 저장소의 `linux-7.3/`에 소스 전체가 커밋돼 있고, 디버그 패치도 적용돼 있다.
  - **오프라인 번들** `cxl-debug-kernel-offline-v7.3.tar` (약 160 MB): kernel.org 원본 `linux-7.3.tar.xz`와 키트가 들어 있다. kernel.org 체크섬과 서명으로 원본임을 확인할 수 있고, 100 MB 이하 분할본도 있다.
- 서버에서는 `setup.sh`가 이 소스로 커널 전체(커널 이미지와 모든 모듈)를 처음부터 빌드한다. 이 과정에서 네트워크 접근은 한 번도 일어나지 않는다.
- 번들의 `cxl-debug-kernel/` 폴더만 따로 옮겼다면 `./setup.sh --tarball /경로/linux-7.3.tar.xz`로 실행한다. 소스가 어디에도 없으면 setup.sh가 git clone을 시도하다가 실패한다.

```
A. (인터넷 PC) 소스(저장소 압축본 또는 번들) + 대상 OS용 패키지 준비
B. (서버) 배치 → 무결성 → 의존성 점검        tools/check-build-deps.sh
C. (서버) 빌드 시작 (백그라운드)              ./setup.sh --build          ← D, E를 하는 동안 돈다
D. 현재 커널에서 수집                         tools/cxl-collect.sh        ← BIOS 증거는 여기서 확보. 빌드가 안 돼도 한다
E. 재부팅 없이 재프로브                       tools/reprobe-trace.sh      ← DUT에 드라이버가 안 붙어 있을 때만
F. 기본 커널 고정 → 디버그 커널 설치 → 1회 부팅
G. 디버그 커널에서 수집 + 비교군 확인
H. 결과 반출 (파일 반출이 안 되면 SHORT.txt 15줄을 옮겨 적는다)
```

---

## A. 인터넷 PC: 소스 + 패키지 준비

1. **소스**는 다음 중 하나로 준비한다.
   - **저장소 압축본** (커밋된 소스 그대로): 브라우저로 https://github.com/HojinNam96/cxl-debug-kernel/archive/refs/heads/main.tar.gz 를 받는다. 파일 이름은 `cxl-debug-kernel-main.tar.gz`이고 크기는 약 270 MB이다.
     - **Windows에서 풀거나 Windows용 git으로 clone하지 않는다.** 대소문자만 다른 커널 경로 13쌍과 symlink 102개가 깨져서 빌드가 실패한다. 받은 `.tar.gz`를 **풀지 않은 채로** 반입한다.
     - 반입 전에 해시를 적어 둔다: `sha256sum cxl-debug-kernel-main.tar.gz` (Windows에서는 `certutil -hashfile cxl-debug-kernel-main.tar.gz SHA256`).
     - 리눅스나 WSL에서는 `git clone --depth 1 https://github.com/HojinNam96/cxl-debug-kernel.git`로 받아도 된다. 반입할 때는 `tar -czf cxl-debug-kernel.tar.gz cxl-debug-kernel`로 묶는다.
     - 자료전송에 100 MB 용량 제한이 있으면 아래 번들의 분할본을 쓴다.
   - **오프라인 번들**을 브라우저로 받기: https://github.com/HojinNam96/cxl-debug-kernel/releases/tag/offline-v7.3
     - `cxl-debug-kernel-offline-v7.3.tar`
     - `cxl-debug-kernel-offline-v7.3.tar.sha256`
     - 용량 제한이 있으면 `.tar.part00`, `.tar.part01`과 `.parts.sha256`
   - 직접 만들기 (리눅스 또는 WSL):
     ```bash
     git clone https://github.com/HojinNam96/cxl-debug-kernel.git && cd cxl-debug-kernel
     ./make-offline-bundle.sh                 # kernel.org에서 받아 sha256과 PGP 서명을 확인하고 묶는다
     ./make-offline-bundle.sh --split 95M     # 자료전송 용량 제한이 있을 때 (95M = 99.6 MB)
     ```
2. **대상 서버의 OS를 미리 알아 둔다.** `cat /etc/os-release`의 `PRETTY_NAME`, 그리고 `uname -r`.
   - Ubuntu Server나 RHEL 최소 설치에는 보통 gcc, flex, bison, libelf/openssl 헤더가 없다.
   - 그러면 B의 결과가 `MISSING`이 된다.
   - 내부 패키지 미러가 없다면 아래 "빠진 패키지 반입"의 패키지를 **번들과 같이 처음부터** 가져간다.
   - RHEL 계열이면 같은 마이너 버전의 DVD ISO가 가장 확실하다.

## B. 서버: 배치 → 무결성 → 의존성 점검

**어디에 풀지:**
- 로컬 리눅스 디스크(ext4/xfs)에 복사한 뒤 푼다. USB, vfat/exFAT/NTFS, noexec 마운트에서는 안 된다.
- 경로에 공백이나 콜론이 없어야 한다 (Kbuild가 거부한다).
- 25 GiB 이상 비어 있어야 한다.
- **일반 사용자**로 풀고 빌드한다. sudo가 필요한 것은 `cxl-collect.sh`, `reprobe-trace.sh`, `make modules_install/install`뿐이다.

**저장소 압축본을 반입했을 때:**
```bash
mkdir -p ~/cxl && cd ~/cxl && cp <반입매체>/cxl-debug-kernel-main.tar.gz .
findmnt -no OPTIONS -T . | grep -qw noexec && echo '이 경로는 noexec: 다른 곳에 푼다'
sha256sum cxl-debug-kernel-main.tar.gz                    # 인터넷 PC에서 적어 둔 값과 같아야 한다
tar -xzf cxl-debug-kernel-main.tar.gz && cd cxl-debug-kernel-main   # 묶어 온 clone이면: tar -xzf cxl-debug-kernel.tar.gz && cd cxl-debug-kernel
ls linux-7.3/Makefile                                     # 커널 소스 전체가 여기 있다 (이미 패치됨)
echo "KIT=$PWD" > ~/cxl.env                               # 재부팅 뒤에도 경로를 다시 찾기 위해
mokutil --sb-state 2>/dev/null; cat /sys/kernel/security/lockdown 2>/dev/null
tools/check-build-deps.sh                                 # 아무것도 설치하지 않고 점검만 한다
```

**번들을 반입했을 때:**
```bash
mkdir -p ~/cxl && cd ~/cxl && cp <반입매체>/cxl-debug-kernel-offline-v7.3.tar* .
findmnt -no OPTIONS -T . | grep -qw noexec && echo '이 경로는 noexec: 다른 곳에 푼다'
# 분할 반입했을 때만:
sha256sum -c cxl-debug-kernel-offline-v7.3.parts.sha256 && cat cxl-debug-kernel-offline-v7.3.tar.part?? > cxl-debug-kernel-offline-v7.3.tar
sha256sum -c cxl-debug-kernel-offline-v7.3.tar.sha256     # .sha256도 같이 반입 (파일 이름이 바뀌었으면 값만 비교)
tar -xf cxl-debug-kernel-offline-v7.3.tar
cd cxl-debug-kernel-offline-v7.3
sha256sum -c --quiet SHA256SUMS && echo OK                # 내부 파일 전부
cd cxl-debug-kernel
echo "KIT=$PWD" > ~/cxl.env                               # 재부팅 뒤에도 경로를 다시 찾기 위해
mokutil --sb-state 2>/dev/null; cat /sys/kernel/security/lockdown 2>/dev/null
tools/check-build-deps.sh                                 # 아무것도 설치하지 않고 점검만 한다
```

**전송 중 손상 확인:**
- 전송 도구가 파일 이름을 바꿨어도 내용만 같으면 된다. 바뀐 이름 그대로 `sha256sum`과 `tar`에 쓴다.
- `.tar`가 아니라 풀린 폴더를 옮겼다면 실행 비트가 빠진다. `chmod +x setup.sh make-offline-bundle.sh tools/*.sh tools/*.py`를 실행한다.
- `SHA256SUMS`에서 `.sh`/`.md`만 FAILED라면 줄바꿈이 바뀐 것이다. 원본 `.tar`를 다시 반입한다.

**`RESULT:`로 시작하는 줄을 보고 할 일:**

| `RESULT:` 줄 | 할 일 |
|---|---|
| `RESULT: OK` | C로 간다 |
| `RESULT: can BUILD here; missing for install/boot only: ...` | C는 시작해도 된다. F 전까지 나열된 항목을 해결한다. `Secure Boot enabled`가 있으면 아래 Secure Boot 절을 본다 |
| `RESULT: MISSING ... needed to build` | 출력된 `apt-get`/`dnf` 명령을 내부 미러로 실행하거나 아래 "빠진 패키지 반입"을 따른다. **그동안 D와 E를 먼저 한다** (빌드가 필요 없다) |

**빌드 의존성:**
- 빌드에 꼭 필요한 것:
  - `make(>=4.0) gcc(>=8.1) binutils(>=2.30) flex bison bc perl awk tar xz gzip openssl`
  - libelf 헤더 (x86 objtool용)
  - openssl 헤더 (모듈 서명용)
- `setup.sh`가 자동으로 맞춰 주는 것 (기본값에서 필요 없게 됨):
  - debug info와 BTF를 끄므로 `pahole`과 `libdw`가 필요 없다.
  - `zstd`/`lz4`가 없으면 모듈 압축을 끄고, 커널 이미지는 gzip으로 압축한다.
  - `gawk`가 없으면 `BUILTIN_MODULE_RANGES`를 끈다.
  - `patch`/`git`이 없으면 체크섬을 확인한 미리 패치된 파일을 쓴다.

**Secure Boot (`SecureBoot enabled`일 때):**
- F에서 직접 빌드한 커널은 shim이 부팅을 거부한다. BMC 원격 콘솔로 BIOS Setup에 들어가 Secure Boot를 끈다. 권한을 미리 확보해 둔다.
- 끌 수 없으면 D와 E만 하고 C/F/G는 생략한다. MOK 서명을 하려면 sbsign/pesign과 콘솔의 MokManager가 필요하다.
- Secure Boot가 켜진 배포판 커널(D)은 `lockdown=integrity`이다.
  - TRIAGE의 MMIO 레지스터 읽기(PCI BAR mmap)는 막힌다. "MMIO ... not readable"로 표시된다.
  - tracefs(E)와 `/proc/dynamic_debug/control`은 동작한다.

### 빠진 패키지 반입 (내부 미러가 없을 때)

check 결과에 나온 패키지 이름을 적어서 다음 중 하나로 해결한다.

1. **설치 ISO를 로컬 저장소로 쓴다 (RHEL 계열, 가장 확실):**
   - 대상 서버와 **같은 마이너 버전**(`cat /etc/redhat-release`)의 DVD ISO를 쓴다.
   - BMC 가상 미디어로 붙였다면 `/dev/sr0`이다.
   ```bash
   sudo mount -o ro,loop rhel-9.x-x86_64-dvd.iso /mnt      # 또는: sudo mount -o ro /dev/sr0 /mnt
   sudo dnf --disablerepo='*' --repofrompath=bos,/mnt/BaseOS --repofrompath=aps,/mnt/AppStream \
        --nogpgcheck install gcc make flex bison bc elfutils-libelf-devel openssl-devel perl
   ```
2. **인터넷 PC에서 대상과 같은 OS 버전의 패키지를 의존성까지 받는다.** 버전이 다르면 libc 같은 기반 패키지가 맞지 않는다.
   - **Ubuntu/Debian:** 대상의 설치 목록을 기준으로 빠진 것만 받는다.
     ```bash
     # 서버에서 (텍스트 파일 1개, 반출 규정 확인):  cp /var/lib/dpkg/status dpkg-status.txt
     # 인터넷 PC에서 (<VER> = 대상의 VERSION_ID, 예: 24.04):
     docker run --rm -v "$PWD:/w" ubuntu:<VER> sh -c 'cp /w/dpkg-status.txt /var/lib/dpkg/status &&
       apt-get update && apt-get install -y --download-only <패키지들> && mkdir -p /w/debs && cp /var/cache/apt/archives/*.deb /w/debs/'
     # 서버에서:  sudo dpkg -i debs/*.deb    (libc6 같은 기반 패키지가 -updates 버전으로 올라갈 수 있다)
     ```
     - status 파일을 반출할 수 없으면 `apt-get install -y --download-only --reinstall libc6 libc-bin libssl3t64 libelf1t64 zlib1g libzstd1 perl-base <패키지들>`로 한다.
     - 22.04에서는 패키지 이름이 `libssl3`, `libelf1`이다.
   - **RHEL 계열:** 같은 메이저.마이너의 Rocky/Alma 컨테이너에서 받아 로컬 저장소로 만든다.
     ```bash
     docker run --rm -v "$PWD/rpms:/out" rockylinux/rockylinux:<9.x> sh -c \
       'dnf -y install dnf-plugins-core createrepo_c && dnf download --resolve --alldeps --destdir /out <패키지들> && createrepo_c /out'
     # 서버에서: 이름으로 설치 (rocky-release 같은 것은 건드리지 않는다)
     sudo dnf --disablerepo='*' --repofrompath=cxl,$PWD/rpms --nogpgcheck install <패키지들>
     ```
     - 대상의 `rpm -q glibc`와 컨테이너의 glibc 버전이 다르면, 대상 마이너 버전의 vault 저장소나 1번(ISO)을 쓴다.
3. **의존성이 갖춰진 다른 내부 리눅스 머신에서 빌드하고 패키지로 설치한다** (대상 서버에는 gcc조차 필요 없다).
   ```bash
   # 대상 서버의 /boot/config-$(uname -r)를 빌드 머신으로 복사한 뒤, 빌드 머신에서:
   tools/check-build-deps.sh --pkg deb          # 또는 --pkg rpm: 패키징 도구까지 확인
   ./setup.sh --base-config /경로/config-<대상커널>
   cd linux-7.3 && make -j$(nproc) bindeb-pkg   # Ubuntu (dpkg-dev, debhelper 필요)
   cd linux-7.3 && make -j$(nproc) binrpm-pkg   # RHEL   (rpm-build 필요)
   ```
   - 결과물 위치:
     - Ubuntu: `cxl-debug-kernel/linux-image-7.3.0-cxldbg_*_amd64.deb` (트리의 상위 폴더)
     - RHEL: `cxl-debug-kernel/linux-7.3/rpmbuild/RPMS/x86_64/kernel-7.3.0_cxldbg-*.x86_64.rpm`
   - 대상 서버에서 F의 "기본 커널 고정"을 한 뒤 `sudo dpkg -i linux-image-*.deb` 또는 `sudo rpm -ivh kernel-7.3.0_cxldbg-*.rpm`를 실행한다.

## C. 빌드 시작 (백그라운드)

```bash
nohup ./setup.sh --build > setup.log 2>&1 &      # 또는 tmux 안에서 ./setup.sh --build
tail -f setup.log                                # 끝나면 ">> built 7.3.0-cxldbg in N min"
```
- 동작:
  - `./linux-7.3`이 있으면(저장소 압축본) 그대로 쓴다. 없으면 `../linux-7.3.tar.xz`를 `./linux-7.3`에 푼다(번들).
  - 패치를 적용한다. 저장소 압축본은 이미 적용돼 있어서 `debug patch already applied`만 찍고 넘어간다.
  - 커널 일부가 아니라 **커널 전체**(이미지와 모든 모듈)를 빌드한다.
  - 지금 커널의 config(`/boot/config-$(uname -r)` 또는 `/proc/config.gz`)에 디버그 옵션을 합친다.
- 배포판 config 처리:
  - signing cert, SBAT, `WERROR`, `PANIC_ON_OOPS`, RUST는 이 디버그 빌드에 맞게 끈다.
  - 배포판 config가 `=m` 대신 `=y`로 강제하는 옵션은 `note:`만 찍고 그대로 진행한다.
  - 정말로 빠진 옵션이 있으면 `DROPPED:`를 찍고 멈춘다.
- 부팅 파라미터 `log_buf_len=64M initcall_debug efi=debug panic=30`은 커널에 **내장**된다(`CONFIG_CMDLINE`). GRUB을 고칠 필요가 없다.
- 결과 커널은 `7.3.0-cxldbg`, 빌드 로그는 `linux-7.3/build.log`이다.
- **걸리는 시간과 공간** (아래 "검증"의 측정값 참고):
  - 실측: Ubuntu 24.04 배포판 config(모듈 6,284개, debug info 끔) 전체 빌드가 16코어에서 13분이었다. 대략 코어 수에 반비례하므로 코어가 많은 Venice 서버에서는 몇 분이면 된다. 대상 서버의 gcc가 더 오래된 버전이면 조금 다를 수 있다.
  - 디스크(실측): 빌드 트리 6.8 GiB, strip한 `/lib/modules/7.3.0-cxldbg` 530 MiB. `/boot`에는 약 300 MiB가 필요하다(initramfs 포함, 추정).
  - 대용량 메모리/CXL 서버는 재부팅(POST)에 5~15분 걸린다. F~G에 최소 30분을 잡는다.

## D. 현재 커널에서 수집 (읽기 전용)

```bash
. ~/cxl.env && cd "$KIT"
lspci -D -nn -k -d ::0502          # CXL 메모리 장치(class 0502). 도메인을 포함한 BDF와 드라이버
DUT=0000:xx:00.0; GOOD=0000:yy:00.0                         # ← 실제 값 (GOOD = region이 잘 생기는 기존 장치)
echo "DUT=$DUT GOOD=$GOOD" >> ~/cxl.env
sudo tools/cxl-collect.sh --bdf $DUT --enable-dyndbg --tag distro
```
- 화면에 `SUMMARY`와 `SHORT`가 출력되고, `cxl-collect-<kernel>-distro-<시각>.tar.gz`가 생긴다.
- **BIOS 레벨**로 모으는 것:
  - BIOS 버전(dmidecode)
  - ACPI `CEDT/SRAT/HMAT` 원본 (iasl이 있으면 디스어셈블까지)
  - ACPI0017/0016
  - `/sys/firmware/memmap`(Soft Reserved), `/proc/iomem`
  - dmesg의 e820/EFI SP 줄
- **OS 레벨**로 모으는 것:
  - DUT와 그 위 root port까지의 `lspci -vvv -xxxx`
  - `/sys/bus/cxl` 전 객체 속성
  - dax, NUMA, 모듈, deferred probe
  - dmesg 요약
- **판정**은 `TRIAGE.txt`(cxl_triage.py)에 들어간다. 단계별 ok/XX와 `VERDICT`(첫 실패 단계와 owner)가 나온다.
- **장치에 보내지 않는 것:**
  - bind/unbind/리셋은 하지 않는다.
  - CXL mailbox 명령도 보내지 않는다. `cxl list`는 `-vv`(sysfs만)로 실행한다. mailbox 질의까지 원하면 `--with-mbox`를 붙인다.
  - MMIO는 Memory Space Enable=1이고 D0인 장치에서만 상태 레지스터를 읽는다.
- `--enable-dyndbg`는 이미 로드된 cxl/dax 모듈의 dev_dbg만 켠다. 부팅 때 지나간 메시지는 되돌아오지 않는다. 그래서 F가 필요하다.

### SUMMARY 읽는 법 (위에서부터 처음 해당하는 줄이 답)

| 보이는 것 | 의미 | 책임 |
|---|---|---|
| `ACPI tables present`에 CEDT가 없고 ACPI0017 = 0 | BIOS가 CXL을 OS에 넘기지 않았다 (BIOS의 CXL 설정이 꺼짐) | BIOS |
| DUT `class` ≠ `0x050210` | cxl_pci가 매칭 자체를 하지 않는다 | DEVICE (config space) |
| DUT `driver=NONE` | cxl_pci 프로브 실패 (또는 매칭 안 됨). **E**에서 errno를 확인한다 | DEVICE 또는 KERNEL |
| `driver=cxl_pci`인데 `memdev=NONE` | 프로브가 **아직 진행 중이거나 멈춘** 상태다. driver 링크는 probe() 전에 생기고 실패하면 지워진다. cxl_pci는 media ready(Range당 최대 60초)와 mailbox ready(60초)를 기다린다. 약 4분 뒤 D를 다시 실행한다. 그래도 같으면 `sudo dmesg \| grep -E 'timeout awaiting\|Media not active\|cxl_pci'`를 보고 F로 간다. 이 상태에서는 E를 할 수 없다 | DEVICE (응답 없음) |
| memN은 있는데 region이 없고, DUT HPA가 memmap Soft Reserved / CFMWS에 없음 | BIOS가 DUT의 HDM decoder를 프로그램하지 않았다 (자동 region 대상이 아님) | BIOS (또는 설계상 수동 `cxl create-region`) |
| TRIAGE `VERDICT` | 위 판정을 자동으로 한 결과다. `owner`와 `next`를 그대로 따른다 | |

## E. 재부팅 없이 재프로브 (DUT에 드라이버가 안 붙어 있을 때)

```bash
. ~/cxl.env && cd "$KIT"
sudo tools/reprobe-trace.sh $DUT      # bind errno + function_graph 트레이스 + dmesg 증분
```
- 결과 파일:
  - `bind-result.txt`: errno
  - `trace.txt`: `cxl_pci_probe` 안에서 어느 함수가 어떤 값을 리턴했는지
- 배포판 커널에는 `funcgraph-retval`이 없을 수 있다 (경고만 출력됨). 그래도 errno와 dyndbg 줄은 남는다.
- **`No such device`(ENODEV) 해석:**
  - `trace.txt`에 `cxl_pci_probe`가 **없으면** 프로브는 호출조차 되지 않았다. class 코드가 맞지 않아 매칭이 안 된 것이다 (D 표 2행). 스크립트도 NOTE로 알려 준다.
  - `cxl_pci_probe`가 **있으면** 프로브가 -ENODEV를 리턴한 것이다 (README 표의 Block ID 03h 행).
- cxl_pci 모듈이 로드되지 않은 상태였다면, 로드하는 순간 장치가 프로브된다. 붙었으면 그 사실과 dmesg 증분을 남기고 끝난다.
- **E를 할 수 없을 때:**
  - `driver=cxl_pci`이면 스크립트가 거부한다. E는 건너뛰고 F로 간다. unbind는 하지 않는다.
  - `tracefs not found`면 안내된 대로 `echo $DUT | sudo tee /sys/bus/pci/drivers/cxl_pci/bind; sudo dmesg | tail -50`으로 errno만 남긴다.
- DUT에 mailbox 명령(Identify 등)이 다시 나간다. 정상 장치는 건드리지 않는다.
- 여기서 원인이 확정되면 F~G는 생략할 수 있다.

## F. 기본 커널 고정 → 디버그 커널 설치 → 1회 부팅

> **주의:** Ubuntu에서는 `make install`을 하면 7.3.0-cxldbg가 버전이 가장 높아 **기본(0번) 항목이 된다**. RHEL도 `/etc/sysconfig/kernel`이 `UPDATEDEFAULT=yes`이면 기본이 바뀐다. 그래서 반드시 **지금 커널을 먼저 고정**한 다음 디버그 커널로 1회만 부팅한다.

```bash
. ~/cxl.env && cd "$KIT"
BASE=$(uname -r); echo "BASE=$BASE" >> ~/cxl.env              # 지금 (배포판) 커널
cat /proc/sys/crypto/fips_enabled 2>/dev/null                 # 1이면 아래 RHEL FIPS 줄도 실행

# --- Ubuntu/Debian ---
sudo cp -a /etc/default/grub /etc/default/grub.before-cxldbg
sudo sed -i -e 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
            -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
(cd linux-7.3 && sudo make INSTALL_MOD_STRIP=1 modules_install && sudo make install)   # update-grub도 실행된다
grep -E "^submenu|menuentry '" /boot/grub/grub.cfg | cut -d"'" -f2                     # 실제 메뉴 이름 확인
sudo grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux $BASE"
sudo grub-reboot      "Advanced options for Ubuntu>Ubuntu, with Linux 7.3.0-cxldbg"
sudo grub-editenv list        # saved_entry=...$BASE 와 next_entry=...7.3.0-cxldbg 두 줄이어야 한다

# --- RHEL 계열 (grubby / BLS) ---
OLD=$(sudo grubby --default-kernel)                           # /boot/vmlinuz-$BASE
(cd linux-7.3 && sudo make INSTALL_MOD_STRIP=1 modules_install && sudo make install)
sudo grubby --set-default="$OLD" && sudo grubby --default-kernel     # 다시 $OLD 인지 확인
sudo grubby --update-kernel=/boot/vmlinuz-7.3.0-cxldbg --remove-args=fips=1   # FIPS 모드일 때만 (HMAC 파일이 없어 부팅 실패 방지)
sudo grub2-reboot "$(sudo grubby --info=/boot/vmlinuz-7.3.0-cxldbg | sed -n 's/^title="\(.*\)"/\1/p')"
sudo grub2-editenv list       # next_entry=... 확인

sudo reboot
```
- 부팅 파라미터는 커널에 내장되어 있다 (C 참고). GRUB이나 grubby에 따로 넣을 필요가 없다.
- **BMC 원격 콘솔(KVM 또는 SOL)을 열어 두고 부팅한다.**
  - 패닉이 나면 `panic=30`이라 30초 뒤 자동으로 재부팅된다. 고정해 둔 배포판 커널로 올라온다.
  - 멈추면 BMC로 power cycle한다.
- 다시 올라온 뒤 직전 디버그 부팅의 로그를 확인하는 방법:
  - 영구 저널(`/var/log/journal`이 있음)이고 journald가 시작된 뒤 멈췄다면, D를 다시 실행했을 때 `log/journal-k-prev-boot.txt`에 직전 부팅 로그가 들어간다.
  - initramfs 단계에서 멈췄다면 BMC 콘솔 화면이 유일한 기록이다.
  - 패닉이었다면 `sudo modprobe efi_pstore; ls /sys/fs/pstore`도 확인한다.

## G. 디버그 커널에서 수집 + 비교군 확인

```bash
. ~/cxl.env && cd "$KIT"            # 재부팅 뒤 경로와 BDF를 다시 읽는다
uname -r                            # 7.3.0-cxldbg 여야 함
grep -o 'initcall_debug' /proc/cmdline
sudo grub-editenv list 2>/dev/null || sudo grub2-editenv list   # next_entry가 비어 있어야 한다 (다음 재부팅 = 배포판 커널)
sudo tools/cxl-collect.sh --bdf $DUT --tag cxldbg
grep -E "$DUT.*cxl_pci_probe|cxl_pci_probe.*$DUT" cxl-collect-*-cxldbg-*/log/dmesg.txt | head  # "<step> failed: <rc>" 또는 "done, memN registered"
grep -E "probe of .* returned -" cxl-collect-*-cxldbg-*/log/dmesg.txt | head -20                # 어떤 객체가 어떤 errno로 실패했는지
```
- `next_entry`가 남아 있으면 `/boot/grub`이 RAID/LVM 위에 있어 GRUB이 지우지 못한 것이다. `sudo grub-editenv /boot/grub/grubenv unset next_entry`로 지운다.
- **비교군:** `SHORT`의 `PCI $GOOD ...` 줄에 memdev가 있어야 하고, `cxl:` 줄의 region 수가 배포판 커널 때와 같아야 한다. 다르면 커널 쪽 차이부터 의심하고, D의 배포판 커널 수집본과 diff한다.
- 실패 단계별 의미는 `README.md`의 "First failing cxl_pci_probe step" 표에 있다.
- DUT에 드라이버가 안 붙었으면 여기서도 `sudo tools/reprobe-trace.sh $DUT`를 실행한다. 이 커널에는 `funcgraph-retval`이 있다.
- 끝나면 그냥 재부팅한다. 고정해 둔 배포판 커널로 돌아간다.

## H. 결과 반출

- **파일 반출이 되면:** 다음을 보낸다.
  - `cxl-collect-*-distro-*.tar.gz`
  - `cxl-collect-*-cxldbg-*.tar.gz`
  - `reprobe-*/`
- **파일 반출이 안 되면:** 각 수집 폴더의 **`SHORT.txt`**(약 15줄)를 옮겨 적거나 사진으로 찍는다. 수집이 끝날 때 화면에도 출력된다.
  - 들어 있는 것:
    - 커널과 BIOS 버전
    - ACPI 테이블과 객체 수, Soft Reserved 수
    - CXL class 장치마다 `PCI <BDF> class driver memdev` 줄
    - cxl 객체 수
    - DUT의 첫 probe 줄 4개
    - TRIAGE의 `first failing stage / evidence / meaning / next` 4줄
  - E를 했다면 `reprobe-*/bind-result.txt`의 2~3줄도 같이 적는다.
- tar에는 서버 정보(BIOS 버전, 메모리 맵, PCI 트리, ACPI 테이블)가 들어 있다. 반출 규정을 확인한다.

## 롤백

- **기본 커널로 돌아가기:** F에서 고정했으면 그냥 재부팅한다. 확인은 `sudo grub-editenv list` 또는 `sudo grubby --default-kernel`로 한다.
- **디버그 커널 삭제** (배포판 커널로 부팅한 상태에서):
  - Ubuntu:
    ```bash
    sudo rm -f /boot/*-7.3.0-cxldbg* && sudo rm -rf /lib/modules/7.3.0-cxldbg /var/lib/initramfs-tools/7.3.0-cxldbg
    sudo mv /etc/default/grub.before-cxldbg /etc/default/grub
    [ -L /boot/vmlinuz ] && sudo ln -sf vmlinuz-$(uname -r) /boot/vmlinuz; [ -L /boot/initrd.img ] && sudo ln -sf initrd.img-$(uname -r) /boot/initrd.img
    sudo update-grub
    ```
  - RHEL:
    ```bash
    sudo kernel-install remove 7.3.0-cxldbg && sudo rm -rf /lib/modules/7.3.0-cxldbg && sudo grubby --default-kernel
    ```
    `grubby --remove-kernel`은 BLS 항목만 지우고 `/boot` 파일은 남긴다.

## 검증 (이 번들을 만들 때 실제로 확인한 것)

모두 `unshare -rn`(네트워크 없는 namespace) 안에서 실행했다. 빌드 호스트는 Ubuntu 26.04, gcc 15.2, 16코어이다.

- **번들 무결성:**
  - kernel.org `linux-7.3.tar.xz`가 kernel.org `sha256sums.asc`와 일치한다.
  - PGP 서명은 Greg Kroah-Hartman 키(647F28654894E3BD457199BE38DBBDC86092693E)로 "Good signature"이다.
- **x86_64 defconfig 전체 빌드:**
  - 압축 해제, 패치, config, 빌드까지 2분(-j16)이 걸렸고 경고는 0건이다.
  - `bzImage`와 CXL/DAX 모듈 11개가 나왔다. `uname -r`은 `7.3.0-cxldbg`이다.
- **`patch`와 `git`이 모두 없는 환경:** 미리 패치된 파일로 대체하는 경로가 동작했다.
- **실제 배포판 config 병합 (`setup.sh --base-config`):** 아래 표.

| 배포판 config | setup.sh 결과 | `make prepare`, `certs/`, `drivers/cxl/ drivers/dax/` |
|---|---|---|
| Ubuntu 26.04 (7.0.0-44-generic) | OK. `LIBNVDIMM=y`(note), zstd 없음 → 모듈 압축 off, gzip 이미지 | OK, 경고 0 |
| Ubuntu 24.04 (6.8.0-151-generic) | OK. `LIBNVDIMM=y`(note), gzip 이미지 | OK, 경고 0 |
| Rocky 9 (5.14.0-741.24.1.el9_9) | OK. `WERROR`/`PANIC_ON_OOPS` off | OK, 경고 0 |
| AlmaLinux 10.3 (6.12.0-264.19.1.el10_3) | OK. 모듈 압축 xz 유지, `WERROR` off | OK, 경고 0 |

- 네 config 모두 결과 `.config`에 `CXL_ATL=y`, `CMDLINE_BOOL=y`, `LOCALVERSION="-cxldbg"`가 들어갔다.
- **Ubuntu 24.04 config 전체 빌드:**
  - `make -j16`이 13분(775초) 걸렸고 rc=0이다.
  - 모듈은 6,284개 나왔다. 경고 16건은 모두 다른 드라이버의 frame-size 경고이고, cxl/dax에는 0건이다.
  - `make INSTALL_MOD_STRIP=1 modules_install`(모듈 서명 포함)도 통과했고 크기는 530 MiB이다.
- **저장소 clone으로 빌드 (2026-11-24):**
  - `git clone --depth 1`로 받은 저장소에는 `linux-7.3/`의 96,080개 항목(symlink 102개 포함)이 다 들어 있었다. `.git` 크기는 297 MB이다.
  - setup.sh는 `using existing kernel tree`, `debug patch already applied`를 찍고 넘어갔다. defconfig 전체 빌드까지 113초 걸렸다.
  - `kernelrelease`는 `+` 없이 `7.3.0-cxldbg`이다.
