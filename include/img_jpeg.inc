# Baseline JPEG decoder context shared by src/fs/img_jpeg*.s (markers, entropy, IDCT/color).

.intel_syntax noprefix

# Huffman table (canonical decode + 8-bit lookup)
.struct 0
HT.look:     .space 512       # u16[256]: len << 8 | symbol (0 = code longer than 8 bits)
HT.maxcode:  .space 18 * 4    # i32[18], index = code length (1..16), [17] = sentinel
HT.valptr:   .space 17 * 4
HT.mincode:  .space 17 * 4
HT.vals:     .space 256
HT._size:

# Frame component
.struct 0
JC.id:       .space 4
JC.h:        .space 4
JC.v:        .space 4
JC.tq:       .space 4
JC.td:       .space 4
JC.ta:       .space 4
JC.pred:     .space 4         # DC predictor
JC.bw:       .space 4         # plane width / height (MCU-padded samples)
JC.bh:       .space 4
JC.sx:       .space 4         # upsampling shifts: x >> sx, y >> sy
JC.sy:       .space 4
JC.pad:      .space 4
JC.plane:    .space 8
JC._size:

.struct 0
Jpeg.qt:     .space 4 * 64 * 2        # u16 quantizers in zigzag order
Jpeg.huff:   .space 8 * HT._size      # 0..3 DC, 4..7 AC
Jpeg.comp:   .space 4 * JC._size
Jpeg.blk:    .space 64 * 4            # i32 coefficients, natural order
Jpeg.tmp:    .space 64 * 4            # IDCT row pass
Jpeg.p:      .space 8                 # entropy reader
Jpeg.end:    .space 8
Jpeg.bits:   .space 8
Jpeg.nbits:  .space 4
Jpeg.marker: .space 4                 # 1 = a marker stopped the reader
Jpeg.ncomp:  .space 4
Jpeg.w:      .space 4
Jpeg.h:      .space 4
Jpeg.hmax:   .space 4
Jpeg.vmax:   .space 4
Jpeg.mcux:   .space 4
Jpeg.mcuy:   .space 4
Jpeg.rst:    .space 4                 # restart interval (MCUs), 0 = none
Jpeg.sncomp: .space 4                 # components in the current scan
Jpeg.scomp:  .space 4 * 4             # their indices
Jpeg.todo:   .space 4                 # MCUs left before the next restart
Jpeg.frame:  .space 4                 # 1 after SOF0/1
Jpeg.out:    .space 8                 # Image *
Jpeg._size:
