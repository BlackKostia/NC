/* tools/abi_verify.c - C11 Compile-Time & Runtime Kernel ABI Verifier for Duop.
 * Verifies include/os/linux/x86_64/pal_target.inc constants against Linux UAPI headers.
 * Compiled standalone with gcc/clang during verification; never linked into duop.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/stat.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>

#ifdef ABI_EMIT
/* Cross mode (tools/abi_cross.py): no libc and no execution. Every fact becomes an absolute
 * assembler symbol abi__NAME that `nm` can read from the object for any --target. */
#define ABI_ENTRY(name, expr) __asm__(".globl abi__" #name "\n.set abi__" #name ", %c0" :: "i"((long long)(expr)));
void abi_emit(void);
void abi_emit(void) {
#include "abi_entries.def"
}
#else
typedef struct {
    const char *name;
    long long expected;
} AbiEntry;

static const AbiEntry k_entries[] = {
#define ABI_ENTRY(name, expr) {#name, (long long)(expr)},
#include "abi_entries.def"
#undef ABI_ENTRY
};

static int lookup_pal_equ(const char *path, const char *sym, long long *out) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[512];
    size_t slen = strlen(sym);
    int found = 0;
    while (fgets(line, sizeof(line), fp)) {
        const char *p = strstr(line, ".equ");
        if (!p) continue;
        p += 4;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, sym, slen) != 0 || p[slen] != ',') continue;
        p += slen + 1;
        while (*p == ' ' || *p == '\t') p++;
        *out = strtoll(p, NULL, 0);
        found = 1;
        break;
    }
    fclose(fp);
    return found;
}

int main(int argc, char **argv) {
    const char *inc_path = argc > 1 ? argv[1] : "include/os/linux/x86_64/pal_target.inc";
    size_t n = sizeof(k_entries) / sizeof(k_entries[0]);
    int failures = 0;
    int checked = 0;
    for (size_t i = 0; i < n; i++) {
        long long actual = 0;
        if (!lookup_pal_equ(inc_path, k_entries[i].name, &actual)) {
            fprintf(stderr, "ABI MISSING: %s not found in %s\n", k_entries[i].name, inc_path);
            failures++;
            continue;
        }
        checked++;
        if (actual != k_entries[i].expected) {
            fprintf(stderr, "ABI MISMATCH: %s: pal_target.inc=%lld (0x%llx) vs kernel=%lld (0x%llx)\n",
                    k_entries[i].name, actual, (unsigned long long)actual,
                    k_entries[i].expected, (unsigned long long)k_entries[i].expected);
            failures++;
        }
    }
    if (failures > 0) return 1;
    printf("C11 KERNEL ABI AUDIT PASSED (%d constants verified against Linux headers)\n", checked);
    return 0;
}
#endif /* ABI_EMIT */
