/* Core helpers that PAL assembly still imports from not-yet-migrated modules; harness-only stand-ins. */
#include <stddef.h>
#include <stdint.h>

void *memcpy(void *restrict d, const void *restrict s, size_t n);
void *mem_copy(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
