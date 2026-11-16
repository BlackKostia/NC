#!/usr/bin/env bash
# Етап 0.0 (HYBRID_PORTABILITY_PLAN): відтворює спайк asm vs freestanding C — розмір .text і швидкість.
# Використання: tools/spike/run_spike.sh   (потрібні gcc, clang, zlib.h)
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="-std=gnu2x -Os -ffreestanding -nostdlib -fno-pic -fno-pie -fcf-protection=none -fno-stack-protector -fno-stack-clash-protection -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident -funsigned-char -fno-strict-aliasing -fno-common"
AS_INC="-I include -I include/os/linux/x86_64 -I build"
mkdir -p build; [ -f build/version.inc ] || make -s build/version.inc
for m in core/utf8 fs/dir_sort_radix fs/inflate fs/inflate_api; do as $AS_INC src/$m.s -o "$T/asm_$(basename $m).o"; done
gcc -O2 -c tools/spike/driver.c -o "$T/driver.o"
for cc in gcc clang; do for m in utf8 radix inflate; do $cc $F -c tools/spike/$m.c -o "$T/$m.$cc.o"; done; done
gcc -no-pie "$T"/driver.o "$T"/asm_*.o -lz -o "$T/bench_asm" 2>/dev/null
for cc in gcc clang; do gcc -no-pie "$T/driver.o" "$T/utf8.$cc.o" "$T/radix.$cc.o" "$T/inflate.$cc.o" -lz -o "$T/bench_$cc"; done
echo "== .text+.rodata (bytes)"; for f in "$T"/asm_utf8.o "$T"/utf8.gcc.o "$T"/utf8.clang.o "$T"/asm_dir_sort_radix.o "$T"/radix.gcc.o "$T"/radix.clang.o "$T"/asm_inflate.o "$T"/asm_inflate_api.o "$T"/inflate.gcc.o "$T"/inflate.clang.o; do printf '%-28s %s\n' "$(basename $f)" "$(size "$f" | awk 'NR==2{print $1}')"; done
for b in asm gcc clang; do echo "== $b"; for i in 1 2 3; do "$T/bench_$b"; done; done
