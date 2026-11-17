# PNG decoder context shared by src/fs/img_png.s (container) and src/fs/img_png_px.s (pixels).

.intel_syntax noprefix

.struct 0
PngCtx.w:       .space 4
PngCtx.h:       .space 4
PngCtx.depth:   .space 4     # bits per sample: 1, 2, 4, 8, 16
PngCtx.ctype:   .space 4     # 0 gray, 2 RGB, 3 palette, 4 gray+alpha, 6 RGBA
PngCtx.ch:      .space 4     # samples per pixel
PngCtx.bits:    .space 4     # bits per pixel
PngCtx.fbpp:    .space 4     # filter distance in bytes (>= 1)
PngCtx.ilace:   .space 4     # 1 = Adam7
PngCtx.plte:    .space 8     # PLTE payload (RGB triples) or 0
PngCtx.plte_n:  .space 4
PngCtx.trns_n:  .space 4
PngCtx.trns:    .space 8     # tRNS payload or 0
PngCtx.idat:    .space 8     # concatenated IDAT payload (heap)
PngCtx.idat_n:  .space 8
PngCtx.raw:     .space 8     # inflated, filtered scanlines (heap)
PngCtx.raw_n:   .space 8
PngCtx.out:     .space 8     # Image *
PngCtx._size:

# Adam7 / plain pass descriptor
.struct 0
PngPass.x0:     .space 4
PngPass.y0:     .space 4
PngPass.dx:     .space 4
PngPass.dy:     .space 4
PngPass.pw:     .space 4
PngPass.ph:     .space 4
PngPass._size:
