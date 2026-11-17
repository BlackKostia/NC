/* src/core/hash.c - IEEE 802.3 CRC32 and FIPS 180-4 SHA-256 (freestanding C23; replaces hash.s).
 *
 * crc32_update works on the raw running value (callers seed 0xFFFFFFFF and invert at the end).
 * ShaCtx (duop_hash.h) keeps the 112-byte layout of the assembly version.
 */
#include "duop_hash.h"

static const uint32_t crc_nibble[16] = {
    0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
    0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c, 0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c,
};

uint32_t crc32_update(uint32_t crc, const uint8_t *buf, size_t len)
{
    while (len--) {
        crc ^= *buf++;
        crc = (crc >> 4) ^ crc_nibble[crc & 15];
        crc = (crc >> 4) ^ crc_nibble[crc & 15];
    }
    return crc;
}

static const uint32_t sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static inline uint32_t rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }

static void sha256_transform(ShaCtx *c, const uint8_t *p)
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->state[0], b = c->state[1], cc = c->state[2], d = c->state[3];
    uint32_t e = c->state[4], f = c->state[5], g = c->state[6], h = c->state[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + sha_k[i] + w[i];
        uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->state[0] += a; c->state[1] += b; c->state[2] += cc; c->state[3] += d;
    c->state[4] += e; c->state[5] += f; c->state[6] += g; c->state[7] += h;
}

void sha256_init(ShaCtx *c)
{
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    for (int i = 0; i < 8; i++) c->state[i] = iv[i];
    c->total = 0;
    c->buflen = 0;
}

void sha256_update(ShaCtx *c, const uint8_t *p, size_t n)
{
    c->total += n;
    while (n) {
        if (c->buflen == 0 && n >= 64) {      /* whole blocks straight from the caller's buffer */
            sha256_transform(c, p);
            p += 64;
            n -= 64;
            continue;
        }
        size_t take = 64 - c->buflen;
        if (take > n) take = n;
        for (size_t i = 0; i < take; i++) c->buf[c->buflen + i] = p[i];
        c->buflen += (uint32_t)take;
        p += take;
        n -= take;
        if (c->buflen == 64) {
            sha256_transform(c, c->buf);
            c->buflen = 0;
        }
    }
}

void sha256_final_hex(ShaCtx *c, char *out)
{
    static const char hex[] = "0123456789abcdef";
    uint64_t bits = c->total << 3;
    uint32_t n = c->buflen;
    c->buf[n++] = 0x80;
    if (n > 56) {
        while (n < 64) c->buf[n++] = 0;
        sha256_transform(c, c->buf);
        n = 0;
    }
    while (n < 56) c->buf[n++] = 0;
    for (int i = 0; i < 8; i++) c->buf[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_transform(c, c->buf);
    for (int i = 0; i < 8; i++)
        for (int sh = 28; sh >= 0; sh -= 4) *out++ = hex[(c->state[i] >> sh) & 15];
    *out = 0;
}
