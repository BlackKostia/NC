/* Decode one file with Duop's real image decoders under a guard-page heap (see guard_alloc.c).
 * The input buffer is placed so that its last byte is the last byte before an unmapped page:
 * any read past the end of the file faults.  usage: decode_one <IMG_FMT_*> <file>
 * exit 0 = decoded, 3 = cleanly rejected, killed by a signal = memory-safety bug. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

char **g_envp;
extern void *guard_exact(size_t);
extern int img_decode(const uint8_t *d, size_t n, int fmt, void *out);
extern void img_free(void *img);

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int fd = open(argv[2], O_RDONLY);
    if (fd < 0) return 2;
    static uint8_t buf[1 << 22];
    ssize_t n = read(fd, buf, sizeof buf);
    if (n <= 0) return 2;
    uint8_t *in = guard_exact((size_t)n);
    if (!in) return 2;
    memcpy(in, buf, (size_t)n);
    uint64_t img[3] = {0};
    int rc = img_decode(in, (size_t)n, atoi(argv[1]), img);
    if (rc == 0) img_free(img);
    return rc == 0 ? 0 : 3;
}
