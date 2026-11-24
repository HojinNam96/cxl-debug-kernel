#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Run on a machine WITH internet. Produces one file to carry into the closed network:
#   cxl-debug-kernel-offline-v7.3.tar  =  linux-7.3.tar.xz (kernel.org, checksum-verified)
#                                         + this kit (patch, config, scripts, RUNBOOK)
#   ./make-offline-bundle.sh [--tarball linux-7.3.tar.xz] [--out DIR] [--split 95M] [--allow-dirty]
# --tarball:     use an already downloaded kernel.org tarball instead of downloading it.
# --split:       also cut the bundle into parts (for transfer systems with a size limit;
#                GNU split M = MiB, so 95M stays under a "100 MB" limit).
# --allow-dirty: package the working tree even if it has uncommitted changes (default: refuse).
set -euo pipefail
V=7.3
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$PWD; TARBALL=""; SPLIT=""; DIRTY=0
URL=https://cdn.kernel.org/pub/linux/kernel/v7.x
while [ $# -gt 0 ]; do
	case "$1" in
	--tarball) TARBALL=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--split) SPLIT=$2; shift 2 ;;
	--allow-dirty) DIRTY=1; shift ;;
	-h|--help) sed -n '3,12p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
NAME=cxl-debug-kernel-offline-v$V
ISGIT=0; git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1 && ISGIT=1
if [ "$ISGIT" = 1 ] && [ -n "$(git -C "$HERE" status --porcelain)" ] && [ "$DIRTY" = 0 ]; then
	git -C "$HERE" status --short >&2
	echo "uncommitted changes in $HERE: commit first (the bundle is 'git archive HEAD'), or pass --allow-dirty" >&2
	exit 1
fi
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
B=$W/$NAME
mkdir -p "$B"

echo ">> kernel source"
if [ -n "$TARBALL" ]; then cp "$TARBALL" "$B/linux-$V.tar.xz"
else curl -fL --retry 3 -o "$B/linux-$V.tar.xz" "$URL/linux-$V.tar.xz"; fi
curl -fsSL --retry 3 -o "$W/sha256sums.asc" "$URL/sha256sums.asc"
curl -fsSL --retry 3 -o "$B/linux-$V.tar.sign" "$URL/linux-$V.tar.sign"
want=$(awk -v f="linux-$V.tar.xz" '$2==f{print $1}' "$W/sha256sums.asc")
got=$(sha256sum "$B/linux-$V.tar.xz" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "sha256 mismatch vs kernel.org sha256sums.asc: $got != $want" >&2; exit 1; }
echo "   sha256 matches kernel.org: $got"
if command -v gpg >/dev/null; then
	export GNUPGHOME=$W/gnupg; mkdir -m 700 "$GNUPGHOME"
	if gpg -q --auto-key-locate wkd --locate-keys torvalds@kernel.org gregkh@kernel.org >/dev/null 2>&1 &&
	   xz -dc "$B/linux-$V.tar.xz" | gpg --verify "$B/linux-$V.tar.sign" - 2>&1 | grep -q 'Good signature'; then
		echo "   PGP signature: good ($(xz -dc "$B/linux-$V.tar.xz" | gpg --verify "$B/linux-$V.tar.sign" - 2>&1 | grep -o 'Good signature from "[^"]*"'))"
	else
		echo "   PGP signature: not verified (no WKD access?) - sha256 check above still holds"
	fi
fi

echo ">> kit"
if [ "$ISGIT" = 1 ] && [ "$DIRTY" = 0 ]; then
	git -C "$HERE" archive --format=tar --prefix=cxl-debug-kernel/ HEAD | tar -x -C "$B"
	git -C "$HERE" describe --always --dirty > "$B/cxl-debug-kernel/KIT_COMMIT"
else
	mkdir "$B/cxl-debug-kernel"
	tar -C "$HERE" --exclude='./linux-*' --exclude='./.git' --exclude='./cxl-collect-*' --exclude='./reprobe-*' -cf - . | tar -x -C "$B/cxl-debug-kernel"
	{ git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown; } > "$B/cxl-debug-kernel/KIT_COMMIT"
fi
cp "$B/cxl-debug-kernel/OFFLINE-README.txt" "$B/README.txt" 2>/dev/null || true

( cd "$B" && sha256sum "linux-$V.tar.xz" "linux-$V.tar.sign" README.txt > SHA256SUMS && find cxl-debug-kernel -type f -print0 | sort -z | xargs -0 sha256sum >> SHA256SUMS )

mkdir -p "$OUT"
tar -C "$W" -cf "$OUT/$NAME.tar" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar" > "$NAME.tar.sha256" )
echo ">> $OUT/$NAME.tar ($(du -h "$OUT/$NAME.tar" | cut -f1))"
cat "$OUT/$NAME.tar.sha256"
if [ -n "$SPLIT" ]; then
	( cd "$OUT" && split -b "$SPLIT" -d -a 2 "$NAME.tar" "$NAME.tar.part" && sha256sum "$NAME.tar".part* > "$NAME.parts.sha256" )
	echo ">> parts: $(cd "$OUT" && ls "$NAME.tar".part* | tr '\n' ' ')"
	echo "   join on the target: sha256sum -c $NAME.parts.sha256 && cat $NAME.tar.part?? > $NAME.tar && sha256sum -c $NAME.tar.sha256"
fi
