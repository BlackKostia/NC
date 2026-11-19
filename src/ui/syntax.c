/* src/ui/syntax.c - Table-driven syntax highlighter for C, ASM, Python, Shell, JSON, Markdown, Makefile
 * (freestanding C23; replaces syntax.s, kept as tests/harness/syntax_reference.s). */
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

static const char *const syn_kw_table[] = {
    "def", "class", "return", "import", "from", "if", "elif", "else",
    "for", "while", "in", "not", "and", "or", "int", "void",
    "char", "struct", "const", "mov", "call", "ret", "jmp", "push",
    "pop", "lea", "cmp", "test", "add", "sub", "xor", "true",
    "false", "null",
};

static int syn_ends_with(const char *s, const char *sfx)
{
    size_t slen = str_len(s);
    size_t xlen = str_len(sfx);
    if (slen < xlen) return 0;
    return str_cmp(s + slen - xlen, sfx) == 0;
}

int syntax_detect(const char *path)
{
    if (!path) return 0;
    if (syn_ends_with(path, ".py") || syn_ends_with(path, ".sh") ||
        syn_ends_with(path, ".s") || syn_ends_with(path, ".asm") ||
        str_cmp(path_basename(path), "Makefile") == 0)
        return 1;
    if (syn_ends_with(path, ".c") || syn_ends_with(path, ".h") ||
        syn_ends_with(path, ".json"))
        return 2;
    if (syn_ends_with(path, ".md")) return 3;
    return 0;
}

static int syn_is_ident(unsigned char c)
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9');
}

static int syn_is_kw(const char *tok, int len)
{
    for (size_t i = 0; i < sizeof(syn_kw_table) / sizeof(syn_kw_table[0]); i++) {
        const char *kw = syn_kw_table[i];
        int n = 0;
        while (n < len && kw[n] && kw[n] == tok[n]) n++;
        if (n == len && kw[n] == '\0') return 1;
    }
    return 0;
}

static int syn_draw_ident(ScreenBuffer *scr, int x, int y, const char *tok, int rem,
                          const Theme *theme, uint32_t bg)
{
    int len = 0;
    while (syn_is_ident((unsigned char)tok[len])) len++;
    if (syn_is_kw(tok, len))
        ScreenBuffer_set_pen(scr, theme->accent, bg, ATTR_BOLD);
    else
        ScreenBuffer_set_pen(scr, theme->text, bg, ATTR_NONE);
    int draw_w = len < rem ? len : rem;
    (void)ScreenBuffer_draw_text(scr, x, y, tok, draw_w);
    return len;
}

static int syn_draw_num(ScreenBuffer *scr, int x, int y, const char *p, int col, int max_w,
                        const Theme *theme, uint32_t bg)
{
    ScreenBuffer_set_pen(scr, theme->warn_fg, bg, ATTR_NONE);
    int n = 0;
    while (col + n < max_w) {
        unsigned char c = (unsigned char)p[n];
        if (!((c >= '0' && c <= '9') || c == 'x' || (c >= 'a' && c <= 'f'))) break;
        ScreenBuffer_set_cell_pen(scr, x + col + n, y, c);
        n++;
    }
    return n;
}

static int syn_draw_str(ScreenBuffer *scr, int x, int y, const char *p, int col, int max_w,
                        const Theme *theme, uint32_t bg)
{
    unsigned char q = (unsigned char)p[0];
    ScreenBuffer_set_pen(scr, theme->exec_fg, bg, ATTR_NONE);
    ScreenBuffer_set_cell_pen(scr, x + col, y, q);
    int n = 1;
    while (col + n < max_w && p[n] != '\0') {
        unsigned char c = (unsigned char)p[n];
        ScreenBuffer_set_cell_pen(scr, x + col + n, y, c);
        n++;
        if (c == q) break;
    }
    return n;
}

void syntax_draw_line(ScreenBuffer *scr, int x, int y, const char *line, int max_w,
                      const char *path, const Theme *theme, uint32_t bg)
{
    int lang = syntax_detect(path);
    if (lang == 0) {
        ScreenBuffer_set_pen(scr, theme->text, bg, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, x, y, line, max_w);
        return;
    }

    const char *p = line;
    int col = 0;
    while (col < max_w && *p != '\0') {
        unsigned char ch = (unsigned char)*p;
        if ((ch == '#' && (lang == 1 || lang == 3)) || (ch == '/' && p[1] == '/')) {
            ScreenBuffer_set_pen(scr, theme->muted, bg, ATTR_NONE);
            (void)ScreenBuffer_draw_text(scr, x + col, y, p, max_w - col);
            return;
        }
        if (ch == '"' || ch == '\'') {
            int n = syn_draw_str(scr, x, y, p, col, max_w, theme, bg);
            p += n;
            col += n;
        } else if (ch >= '0' && ch <= '9') {
            int n = syn_draw_num(scr, x, y, p, col, max_w, theme, bg);
            p += n;
            col += n;
        } else if (syn_is_ident(ch)) {
            int n = syn_draw_ident(scr, x + col, y, p, max_w - col, theme, bg);
            p += n;
            col += n;
        } else {
            ScreenBuffer_set_pen(scr, theme->text, bg, ATTR_NONE);
            ScreenBuffer_set_cell_pen(scr, x + col, y, ch);
            p++;
            col++;
        }
    }
}
