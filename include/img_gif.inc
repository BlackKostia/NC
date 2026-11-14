# GIF decoder context shared by src/fs/img_gif.s (container) and src/fs/img_gif_lzw.s (LZW).

.intel_syntax noprefix

# GifCtx (stack)
.equ GC_PAL,   0               # palette (RGB triples)
.equ GC_PALN,  8
.equ GC_TRANS, 12              # transparent index or -1
.equ GC_IX,    16
.equ GC_IY,    20
.equ GC_IW,    24
.equ GC_IH,    28
.equ GC_ILACE, 32
.equ GC_C1,    36              # interlace pass row counts
.equ GC_C2,    40
.equ GC_C3,    44
.equ GC_POS,   48              # pixels emitted
.equ GC_CW,    52              # canvas size
.equ GC_CH,    56
.equ GC_PX,    64              # canvas pixels
.equ GC_DATA,  72              # gathered LZW bytes
.equ GC_DLEN,  80
.equ GC_MCS,   88              # minimum code size
.equ GC_TAB,   96              # prefix[4096] u16 | suffix[4096] u8 | stack[4097]
.equ GC_SIZE,  104
.equ GIF_TAB_BYTES, 4096 * 2 + 4096 + 4112

