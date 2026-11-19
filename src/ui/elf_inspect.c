/* src/ui/elf_inspect.c - ELF64 header & section inspector for PreviewPane
 * (freestanding C23; replaces elf_inspect.s, kept as tests/harness/elf_inspect_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

#define ELF_MAGIC_LE 0x464c457fu
#define ELF_FULL_CAP 2097152u

static void elf_draw_sections(const PreviewPane *pv, ScreenBuffer *scr, const Theme *theme,
                              const uint8_t *buf, uint64_t buf_len, int y)
{
    if (buf_len < 64) return;
    uint64_t e_shoff = load_le64(buf + 40);
    uint32_t e_shnum = load_le16(buf + 60);
    uint32_t e_shstrndx = load_le16(buf + 62);
    if (e_shoff == 0 || e_shnum == 0 || e_shstrndx >= e_shnum) return;
    if (e_shoff >= buf_len || (uint64_t)e_shnum * 64 > buf_len - e_shoff) return;

    const uint8_t *shstr = buf + e_shoff + (uint64_t)e_shstrndx * 64;
    uint64_t str_off = load_le64(shstr + 24);
    uint64_t str_sz = load_le64(shstr + 32);
    if (str_off >= buf_len || str_sz > buf_len - str_off) return;

    ScreenBuffer_set_pen(scr, theme->muted, theme->surface, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, pv->base.x + 2, y, "Sections:", pv->base.w - 4);
    y++;

    char sec[256];
    for (uint32_t i = 0; i < e_shnum; i++) {
        if (y - pv->base.y >= pv->base.h) break;
        uint32_t sh_name = load_le32(buf + e_shoff + (uint64_t)i * 64);
        if (sh_name >= buf_len - str_off) continue;
        uint64_t off = str_off + sh_name;
        if (buf[off] == 0) continue;
        uint64_t max_n = buf_len - off;
        if (max_n > 255) max_n = 255;
        uint64_t n = 0;
        while (n < max_n && buf[off + n] != 0) {
            sec[n] = (char)buf[off + n];
            n++;
        }
        sec[n] = '\0';
        (void)ScreenBuffer_draw_text(scr, pv->base.x + 3, y, sec, pv->base.w - 5);
        y++;
    }
}

static void elf_maybe_load_full(const PreviewPane *pv, const uint8_t **buf, uint64_t *buf_len,
                                void **full_buf)
{
    *full_buf = nullptr;
    uint64_t e_shoff = load_le64(*buf + 40);
    uint64_t sh_bytes = (uint64_t)load_le16(*buf + 60) * 64;
    if (e_shoff > *buf_len || sh_bytes > *buf_len - e_shoff) {
        size_t flen = 0;
        intptr_t rc = fs_read_file_alloc((const char *)pv->target_path, ELF_FULL_CAP, full_buf, &flen);
        if (rc >= 0 && *full_buf && flen >= 64) {
            const uint8_t *fb = (const uint8_t *)*full_buf;
            if (load_le32(fb) == ELF_MAGIC_LE && fb[4] == 2) {
                *buf = fb;
                *buf_len = flen;
            }
        }
    }
}

static void elf_render_body(const PreviewPane *pv, ScreenBuffer *scr, const Theme *theme,
                            const uint8_t *buf, uint64_t buf_len)
{
    char line[256];
    char num[32];
    int x = pv->base.x + 2;
    int y = pv->base.y + 3;
    int max_w = pv->base.w - 4;

    ScreenBuffer_set_pen(scr, theme->accent, theme->surface, ATTR_BOLD);
    uint16_t e_machine = load_le16(buf + 18);
    const char *m_str = e_machine == 62 ? "ELF64 x86-64" : (e_machine == 183 ? "ELF64 AArch64" : "ELF64");
    (void)str_copy(line, m_str, sizeof line);
    uint16_t e_type = load_le16(buf + 16);
    if (e_type == 1) (void)str_cat(line, " ET_REL", sizeof line);
    else if (e_type == 2) (void)str_cat(line, " ET_EXEC", sizeof line);
    else if (e_type == 3) (void)str_cat(line, " ET_DYN", sizeof line);
    (void)ScreenBuffer_draw_text(scr, x, y++, line, max_w);

    ScreenBuffer_set_pen(scr, theme->text, theme->surface, ATTR_NONE);
    (void)str_copy(line, "Entry: 0x", sizeof line);
    (void)u64_to_hex(load_le64(buf + 24), num, 16);
    (void)str_cat(line, num, sizeof line);
    (void)ScreenBuffer_draw_text(scr, x, y++, line, max_w);

    (void)str_copy(line, "Phdrs: ", sizeof line);
    (void)u64_to_dec(load_le16(buf + 56), num);
    (void)str_cat(line, num, sizeof line);
    (void)str_cat(line, "  Shdrs: ", sizeof line);
    (void)u64_to_dec(load_le16(buf + 60), num);
    (void)str_cat(line, num, sizeof line);
    (void)ScreenBuffer_draw_text(scr, x, y++, line, max_w);

    elf_draw_sections(pv, scr, theme, buf, buf_len, y);
}

static int elf_try_render(const PreviewPane *pv, ScreenBuffer *scr, const Theme *theme,
                          const uint8_t *buf, uint64_t buf_len)
{
    DUOP_TRY_BEGIN(tf, sig) {
        elf_render_body(pv, scr, theme, buf, buf_len);
        DUOP_TRY_END(tf);
    }
    return sig == 0 ? 1 : 0;
}

int elf_preview_try_render(PreviewPane *pv, ScreenBuffer *scr, const Theme *theme)
{
    const uint8_t *buf = (const uint8_t *)(uintptr_t)pv->buf;
    uint64_t buf_len = pv->buf_len;
    if (!buf || buf_len < 64) return 0;
    if (load_le32(buf) != ELF_MAGIC_LE || buf[4] != 2) return 0;

    void *full_buf = nullptr;
    elf_maybe_load_full(pv, &buf, &buf_len, &full_buf);
    int ok = elf_try_render(pv, scr, theme, buf, buf_len);
    if (full_buf) mem_free(full_buf);
    return ok;
}
