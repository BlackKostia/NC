/* src/core/mem_prims.c - memcpy/memmove/memset/memcmp/bcmp that freestanding C compilers emit on their own
 * (struct copies, array init, loop idioms). Thin wrappers over the PAL SIMD primitives (pal_simd.s). */
#include "duop_abi.h"

void *memcpy(void *restrict dst, const void *restrict src, size_t n)
{
    os_mem_copy_fast(dst, src, n);
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    os_mem_move_fast(dst, src, n);
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    os_mem_set_fast(dst, c, n);
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    return os_mem_cmp_fast(a, b, n);
}

int bcmp(const void *a, const void *b, size_t n)
{
    return os_mem_cmp_fast(a, b, n);
}
