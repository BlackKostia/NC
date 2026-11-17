/* src/core/hash_file.c - CRC32 + SHA-256 of one file in 16 KiB reads (freestanding C23; replaces hash_file.s). */
#include "duop_hash.h"
#include "duop_pal.h"

void *mem_alloc(size_t size);
void mem_free(void *ptr);
intptr_t sys_read_retry(int fd, void *buf, size_t len);

enum { HASH_CHUNK = 16384 };

intptr_t hash_file(const char *path, uint32_t *out_crc32, char *out_sha_hex65)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0);
    if (fd < 0) return fd;
    FileStat st;
    uint8_t *buf = nullptr;
    if (os_fstat((int)fd, &st) >= 0 && (st.mode & S_IFMT) == S_IFREG) buf = mem_alloc(HASH_CHUNK);
    if (!buf) {
        (void)os_close((int)fd);
        return -1;
    }
    ShaCtx ctx;
    sha256_init(&ctx);
    uint32_t crc = 0xFFFFFFFFu;
    intptr_t rc = 0;
    for (;;) {
        intptr_t n = sys_read_retry((int)fd, buf, HASH_CHUNK);
        if (n < 0) { rc = -1; break; }
        if (n == 0) break;
        crc = crc32_update(crc, buf, (size_t)n);
        sha256_update(&ctx, buf, (size_t)n);
    }
    if (rc == 0) {
        *out_crc32 = ~crc;
        sha256_final_hex(&ctx, out_sha_hex65);
    }
    mem_free(buf);
    (void)os_close((int)fd);
    return rc;
}
