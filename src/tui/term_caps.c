/* src/tui/term_caps.c - terminal graphics capabilities (freestanding C23; replaces term_caps.s).
 *
 * Which image protocol to use (Kitty / Sixel / quadrant or half blocks), the cell size in pixels (TIOCGWINSZ or the
 * CSI 16 t reply) and a filter that removes terminal replies (DA1 "CSI ? ... c", "CSI 6 ; h ; w t") from the input
 * stream before key parsing. */
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"

static int32_t g_ic_proto = IMG_PROTO_QUAD;
static int32_t g_ic_forced;           /* protocol chosen by DUOP_IMG_MODE / environment (DA1 cannot change it) */
static uint32_t g_ic_cw, g_ic_ch;     /* cell size in pixels (0 = unknown) */
static uint32_t g_ic_rcw, g_ic_rch;   /* cell size from the CSI 16 t reply */
static int32_t g_ic_changed;

/* does environment variable `name` contain `needle` (case-insensitive)? */
static bool ci_env_has(char **envp, const char *name, const char *needle)
{
    const char *v = env_getenv(envp, name);
    return v && str_contains_ci(v, needle);
}

static bool ci_kitty_env(char **envp)   /* Kitty, WezTerm or Ghostty */
{
    return env_getenv(envp, "KITTY_WINDOW_ID") || ci_env_has(envp, "TERM", "kitty") ||
           ci_env_has(envp, "TERM_PROGRAM", "wezterm") || ci_env_has(envp, "TERM_PROGRAM", "ghostty");
}

void term_caps_init(char **envp)
{
    g_ic_proto = IMG_PROTO_QUAD;
    const char *mode = env_getenv(envp, "DUOP_IMG_MODE");
    int32_t proto;
    if (mode) {                                       /* any other value: plain blocks, no detection */
        proto = !str_casecmp(mode, "halfblock") ? IMG_PROTO_HALF : !str_casecmp(mode, "sixel") ? IMG_PROTO_SIXEL
              : !str_casecmp(mode, "kitty") ? IMG_PROTO_KITTY : IMG_PROTO_QUAD;
    } else if (ci_kitty_env(envp)) {
        proto = IMG_PROTO_KITTY;
    } else {
        return;
    }
    g_ic_proto = proto;
    g_ic_forced = 1;
}

void term_caps_query(void)
{
    static const char q[] = "\x1b[c\x1b[16t";
    (void)sys_write_all(1, q, sizeof q - 1);
}

void term_caps_refresh(int cols, int rows)
{
    int xp = 0, yp = 0;
    os_get_winsize_px(&xp, &yp);
    uint32_t cw = g_ic_rcw, ch = g_ic_rch;
    if (xp && yp && cols && rows) {
        cw = (uint32_t)xp / (uint32_t)cols;
        ch = (uint32_t)yp / (uint32_t)rows;
    }
    if (cw == g_ic_cw && ch == g_ic_ch) return;
    g_ic_cw = cw;
    g_ic_ch = ch;
    g_ic_changed = 1;
}

int term_img_proto(void) { return g_ic_proto; }

CellPx term_cell_px(void) { return (CellPx){g_ic_cw, g_ic_ch}; }

int term_caps_changed(void)
{
    int r = g_ic_changed;
    g_ic_changed = 0;
    return r;
}

/* Is p (just after "ESC [") a terminal reply? Returns the bytes it spans (0 = not a reply) and records what it says. */
static size_t cf_reply(const uint8_t *p, const uint8_t *end)
{
    const uint8_t *start = p;
    uint32_t flags = 0, params[3] = {0, 0, 0}, n = 0;   /* flags: 1 = '?', 2 = parameter 4 present */
    if (*p == '?') { flags |= 1; p++; }
    for (;;) {
        if (p >= end) return 0;
        uint32_t v = parse_uint_adv(&p);
        if (v == 4) flags |= 2;
        if (n < 3) params[n] = v;
        n++;
        if (p >= end) return 0;
        uint32_t c = *p++;
        if (c == ';') continue;
        if (c == 'c') {                                 /* DA1: "CSI ? ... 4 ... c" = Sixel */
            if (!(flags & 1)) return 0;
            if ((flags & 2) && !g_ic_forced && g_ic_proto != IMG_PROTO_SIXEL) {
                g_ic_proto = IMG_PROTO_SIXEL;
                g_ic_changed = 1;
            }
        } else if (c == 't') {                          /* CSI 6 ; height ; width t */
            if (flags & 1) return 0;
            if (params[0] == 6) {
                g_ic_rch = params[1];
                g_ic_rcw = params[2];
                if (!g_ic_cw) {                         /* no TIOCGWINSZ pixels: use the reply */
                    g_ic_cw = params[2];
                    g_ic_ch = params[1];
                    g_ic_changed = 1;
                }
            }
        } else {
            return 0;
        }
        return (size_t)(p - start);
    }
}

int term_caps_filter(uint8_t *buf, int from, int len)
{
    int removed = 0;
    for (int i = from; i + 2 < len;) {
        if (buf[i] != 0x1B || buf[i + 1] != '[') { i++; continue; }
        size_t n = cf_reply(buf + i + 2, buf + len);
        if (!n) { i++; continue; }
        n += 2;
        removed += (int)n;
        mem_move(buf + i, buf + i + n, (size_t)(len - i) - n);      /* splice the reply out */
        len -= (int)n;
    }
    return removed;
}
