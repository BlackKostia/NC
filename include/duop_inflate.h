/* include/duop_inflate.h - DEFLATE / zlib decompressor (src/fs/inflate.c). */
#pragma once
#include "duop_abi.h"

/* Both return the bytes written to dst (at most dst_cap) or -1 for a malformed stream. */
int64_t inflate_raw(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap);
int64_t inflate_zlib(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap);   /* RFC 1950 wrapper */
