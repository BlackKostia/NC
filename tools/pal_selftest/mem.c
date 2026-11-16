/* tools/pal_selftest/mem.c - compiler-required mem* primitives for freestanding builds (portable, volatile-free). */
#include <stddef.h>
#include <stdint.h>

/* Keeps the compiler from re-recognising these loops as calls to the very functions being defined. */
#define BARRIER() __asm__ volatile("" ::: "memory")

void *memcpy(void *restrict d, const void *restrict s, size_t n)
{
    uint8_t *dp = d; const uint8_t *sp = s;
    while (n--) { *dp++ = *sp++; BARRIER(); }
    return d;
}
void *memmove(void *d, const void *s, size_t n)
{
    uint8_t *dp = d; const uint8_t *sp = s;
    if (dp < sp) { while (n--) { *dp++ = *sp++; BARRIER(); } }
    else { dp += n; sp += n; while (n--) { *--dp = *--sp; BARRIER(); } }
    return d;
}
void *memset(void *d, int c, size_t n)
{
    uint8_t *dp = d;
    while (n--) { *dp++ = (uint8_t)c; BARRIER(); }
    return d;
}
int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++) if (*x != *y) return *x < *y ? -1 : 1;
    return 0;
}

/* x86_64 PAL objects (pal_uring) call the core allocator helper mem_copy(); in this build it is memcpy. */
void *mem_copy(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
