/* Freestanding differential harness for src/ui/elf_inspect.c versus frozen x86_64 asm
 * (tests/harness/elf_inspect_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   F <x> <y> <w> <h> <cut> <claim> <buf_file> <target_path|->
 *       Load <cut> bytes of <buf_file> at the end of a page followed by an unmapped guard page,
 *       set pv.buf_len = <claim> (if <claim> > <cut>, reading past <cut> triggers SIGSEGV caught by TRY),
 *       set pv.target_path = <target_path> (or ""), call elf_preview_try_render(&pv, scr, theme),
 *       verify mem_alloc/mem_free balance, print rc + ui_dump.
 *   N <len>
 *       C-only NULL-buf safety test: pv.buf = 0, pv.buf_len = <len>. */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_event.h"
#include "ui_render.h"

static int g_live_allocs;
void *ei_alloc(size_t n);
void ei_free(void *p);
void *ei_alloc(size_t n)
{
    void *p = mem_alloc(n);
    if (p) g_live_allocs++;
    return p;
}
void ei_free(void *p)
{
    if (p) g_live_allocs--;
    mem_free(p);
}

#define mem_alloc ei_alloc
#include FOR_SRC
#undef mem_alloc

#define mem_free ei_free
#include EI_SRC
#undef mem_free

#ifdef __x86_64__
extern int ref_elf_preview_try_render(PreviewPane *pv, ScreenBuffer *scr, const Theme *theme);
#define CALL_ELF(p, s, t) (g_ref ? ref_elf_preview_try_render(p, s, t) : elf_preview_try_render(p, s, t))
#else
#define CALL_ELF(p, s, t) elf_preview_try_render(p, s, t)
#endif

static bool g_ref;
static PreviewPane g_pv;

static void next_word(const char **p, char *dst, size_t cap)
{
    while (**p == ' ') (*p)++;
    size_t i = 0;
    while (**p && **p != ' ' && i + 1 < cap) dst[i++] = *(*p)++;
    dst[i] = 0;
}

static void run_file(ScreenBuffer *scr, const Theme *theme, const char *a)
{
    int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
    int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
    size_t cut = (size_t)ui_parse_num(&a);
    size_t claim = (size_t)ui_parse_num(&a);
    char bpath[256], tpath[256];
    next_word(&a, bpath, sizeof bpath);
    next_word(&a, tpath, sizeof tpath);

    intptr_t fd = os_openat(AT_FDCWD, bpath, O_RDONLY | O_CLOEXEC, 0);
    FileStat st;
    if (fd < 0 || os_fstat((int)fd, &st) != 0) {
        if (fd >= 0) (void)os_close((int)fd);
        sc_put("F nofile\n");
        return;
    }
    size_t fsz = (size_t)st.size;
    if (cut > fsz) cut = fsz;

    /* Put the buffer right up against an unmapped trailing guard page. */
    size_t pages = (cut + 4095) / 4096 + 1;
    intptr_t m = os_mmap(nullptr, pages * 4096, PROT_RW, MAP_PRIVATE_ANON, -1, 0);
    if (os_is_err(m)) {
        (void)os_close((int)fd);
        sc_put("F nommap\n");
        return;
    }
    uint8_t *base = (uint8_t *)m;
    uint8_t *data = base + (pages - 1) * 4096 - cut;
    (void)os_munmap_raw(base + (pages - 1) * 4096, 4096);
    for (size_t got = 0; got < cut;) {
        intptr_t r = os_read((int)fd, data + got, cut - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    (void)os_close((int)fd);

    mem_zero(&g_pv, sizeof g_pv);
    g_pv.base.x = x; g_pv.base.y = y; g_pv.base.w = w; g_pv.base.h = h;
    g_pv.buf = (uint64_t)(uintptr_t)data;
    g_pv.buf_len = claim;
    if (!(tpath[0] == '-' && tpath[1] == 0))
        (void)str_copy((char *)g_pv.target_path, tpath, sizeof g_pv.target_path);

    ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
    int before = g_live_allocs;
    int rc = CALL_ELF(&g_pv, scr, theme);
    int leaked = g_live_allocs - before;
    (void)os_munmap_raw(base, (pages - 1) * 4096);

    sc_put("F rc="); sc_num(rc); sc_put(" leak="); sc_num(leaked); sc_put("\n");
    int dump_h = y + h + 2 <= scr->height ? h + 2 : scr->height - y;
    ui_dump(scr, y, dump_h);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    os_fault_guard_install();

    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(64, 16);
    if (!scr) return 3;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        if (line[0] == 'F') {
            run_file(scr, theme, line + 1);
        } else if (line[0] == 'N') {
            const char *a = line + 1;
            mem_zero(&g_pv, sizeof g_pv);
            g_pv.base.w = 60; g_pv.base.h = 12;
            g_pv.buf = 0;
            g_pv.buf_len = (uint64_t)ui_parse_num(&a);
            int rc = elf_preview_try_render(&g_pv, scr, theme);
            sc_put("N rc="); sc_num(rc); sc_put("\n");
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
