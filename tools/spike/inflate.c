/* Spike (Етап 0.0): src/fs/inflate.s + inflate_api.s у freestanding C23. */
#include <stdint.h>
#include <stddef.h>

typedef struct {
    const uint8_t *src, *src_end;
    uint64_t bitbuf;
    uint32_t bitcnt;
    uint8_t *dst, *dst_start, *dst_end;
} InfState;

typedef struct { uint16_t counts[16]; uint16_t offsets[16]; uint16_t symbols[320]; } InfTree;

static const uint16_t len_base[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
static const uint8_t len_ext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
static const uint16_t dist_base[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
static const uint8_t dist_ext[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};
static const uint8_t cl_order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};

static uint32_t bits(InfState *st, uint32_t n)
{
    while (st->bitcnt < n) {
        if (st->src >= st->src_end) { st->bitcnt = n; break; }
        st->bitbuf |= (uint64_t)*st->src++ << st->bitcnt;
        st->bitcnt += 8;
    }
    uint32_t r = (uint32_t)(st->bitbuf & ((1ull << n) - 1));
    st->bitbuf >>= n;
    st->bitcnt -= n;
    return r;
}

static void build_tree(const uint8_t *lens, uint32_t n, InfTree *t)
{
    for (int i = 0; i < 32; i++) ((uint16_t *)t)[i] = 0;
    for (uint32_t i = 0; i < n; i++) if (lens[i] <= 15) t->counts[lens[i]]++;
    t->counts[0] = 0;
    uint32_t sum = 0;
    for (int i = 1; i < 16; i++) { t->offsets[i] = (uint16_t)sum; sum += t->counts[i]; }
    for (uint32_t i = 0; i < n; i++) {
        if (!lens[i]) continue;
        uint32_t o = t->offsets[lens[i]]++;
        if (o < 320) t->symbols[o] = (uint16_t)i;
    }
}

static int decode(InfState *st, const InfTree *t)
{
    uint32_t code = 0, first = 0, index = 0;
    for (uint32_t len = 1; len <= 15; len++) {
        code = (code << 1) | bits(st, 1);
        uint32_t count = t->counts[len];
        if (code - first < count) {
            uint32_t i = index + (code - first);
            return i < 320 ? t->symbols[i] : -1;
        }
        index += count;
        first = (first + count) << 1;
    }
    return -1;
}

static int block_stored(InfState *st)
{
    st->bitbuf >>= (st->bitcnt & 7);
    st->bitcnt -= st->bitcnt & 7;
    uint32_t len = bits(st, 16);
    uint32_t nlen = bits(st, 16);
    if ((~nlen & 0xFFFF) != len) return -1;
    if (len > (size_t)(st->dst_end - st->dst) || len > (size_t)(st->src_end - st->src)) return -1;
    for (uint32_t i = 0; i < len; i++) st->dst[i] = st->src[i];
    st->src += len; st->dst += len;
    return 0;
}

static int block_huff(InfState *st, const InfTree *lit, const InfTree *dist)
{
    for (;;) {
        int s = decode(st, lit);
        if (s < 0) return -1;
        if (s == 256) return 0;
        if (s < 256) {
            if (st->dst >= st->dst_end) return -1;
            *st->dst++ = (uint8_t)s;
            continue;
        }
        s -= 257;
        if (s >= 29) return -1;
        uint32_t len = len_base[s];
        if (len_ext[s]) len += bits(st, len_ext[s]);
        int d = decode(st, dist);
        if (d < 0 || d >= 30) return -1;
        uint32_t dd = dist_base[d];
        if (dist_ext[d]) dd += bits(st, dist_ext[d]);
        uint8_t *from = st->dst - dd;
        if (from < st->dst_start || len > (size_t)(st->dst_end - st->dst)) return -1;
        for (uint32_t i = 0; i < len; i++) st->dst[i] = from[i];
        st->dst += len;
    }
}

static void build_fixed(InfTree *lit, InfTree *dist)
{
    uint8_t l[288];
    int i = 0;
    for (; i < 144; i++) l[i] = 8;
    for (; i < 256; i++) l[i] = 9;
    for (; i < 280; i++) l[i] = 7;
    for (; i < 288; i++) l[i] = 8;
    build_tree(l, 288, lit);
    for (i = 0; i < 32; i++) l[i] = 5;
    build_tree(l, 32, dist);
}

static int load_dyn(InfState *st, InfTree *lit, InfTree *dist)
{
    uint8_t lens[320] = {0};
    uint32_t hlit = bits(st, 5) + 257, hdist = bits(st, 5) + 1, hclen = bits(st, 4) + 4;
    for (uint32_t i = 0; i < hclen; i++) lens[cl_order[i]] = (uint8_t)bits(st, 3);
    build_tree(lens, 19, lit);
    uint32_t total = hlit + hdist, n = 0;
    while (n < total) {
        int s = decode(st, lit);
        if (s < 0) return -1;
        if (s < 16) { lens[n++] = (uint8_t)s; continue; }
        uint32_t rep; uint8_t v = 0;
        if (s == 16) { if (!n) return -1; rep = bits(st, 2) + 3; v = lens[n - 1]; }
        else if (s == 17) rep = bits(st, 3) + 3;
        else rep = bits(st, 7) + 11;
        if (n + rep > total) return -1;
        while (rep--) lens[n++] = v;
    }
    build_tree(lens, hlit, lit);
    build_tree(lens + hlit, hdist, dist);
    return 0;
}

int64_t inflate_raw(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap)
{
    InfState st = {src, (const uint8_t *)src + src_len, 0, 0, dst, dst, (uint8_t *)dst + dst_cap};
    InfTree lit, dist;
    uint32_t last;
    do {
        last = bits(&st, 1);
        uint32_t type = bits(&st, 2);
        int r;
        if (type == 0) r = block_stored(&st);
        else if (type == 1) { build_fixed(&lit, &dist); r = block_huff(&st, &lit, &dist); }
        else if (type == 2) { r = load_dyn(&st, &lit, &dist); if (r >= 0) r = block_huff(&st, &lit, &dist); }
        else r = -1;
        if (r < 0) return -1;
    } while (!last);
    return st.dst - st.dst_start;
}

int64_t inflate_zlib(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap)
{
    const uint8_t *p = src;
    if (src_len < 6 || (p[0] & 0x0F) != 8) return -1;
    uint64_t skip = 2;
    if (p[1] & 0x20) { if (src_len - 2 < 4) return -1; skip = 6; }
    return inflate_raw(p + skip, src_len - skip, dst, dst_cap);
}
