/* Freestanding harness: frozen asm input stack (ref_ prefix) next to src/tui/{input,input_parse,input_seq,term_caps}.c.
 *   <ref|c> events          every event of stdin until EOF, then the terminal-capability state
 *   <ref|c> filter <from>   term_caps_filter over all of stdin (offset `from`), the removed count and the bytes left
 *   <ref|c> init            term_caps_init(envp), then a DA1 reply with Sixel through the filter
 *   <ref|c> refresh <c> <r> term_caps_refresh(c, r) after a CSI 6;h;w t reply; stdout should be a pty with a pixel size
 *   <ref|c> aux <ms>        an aux pipe that is readable ends the idle wait early (prints result and elapsed ms)
 *   <ref|c> winch | probe | uint <text>
 * Output is text, so the test can diff the asm against the C byte for byte. */
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"

extern int ref_input_next_event(Event *, int);
extern int ref_input_probe_eof(void);
extern int ref_input_is_eof(void);
extern void ref_input_set_aux_fd(int, int);
extern uint64_t ref_parse_uint(const char *);
extern void ref_term_caps_init(char **);
extern void ref_term_caps_refresh(int, int);
extern int ref_term_caps_filter(uint8_t *, int, int);
extern int ref_term_img_proto(void);
extern CellPx ref_term_cell_px(void);
extern int ref_term_caps_changed(void);

static bool g_ref;
static char g_out[1 << 16];
static size_t g_n;

static void put(const char *s) { while (*s && g_n < sizeof g_out - 1) g_out[g_n++] = *s++; }
static void flush(void) { (void)os_write(1, g_out, g_n); g_n = 0; }
static void num(const char *k, int64_t v)
{
    char t[24];
    put(k);
    if (v < 0) { put("-"); v = -v; }
    t[u64_to_dec((uint64_t)v, t)] = 0;
    put(t);
    put(" ");
}
static void hex(const char *k, uint64_t v)
{
    char t[24];
    put(k);
    t[u64_to_hex(v, t, 1)] = 0;
    put(t);
    put(" ");
}
static void caps(void)
{
    CellPx px = g_ref ? ref_term_cell_px() : term_cell_px();
    num("proto=", g_ref ? ref_term_img_proto() : term_img_proto());
    num("cw=", (int64_t)px.w);
    num("ch=", (int64_t)px.h);
    num("changed=", g_ref ? ref_term_caps_changed() : term_caps_changed());
    put("\n");
}
static int next(Event *e, int ms) { return g_ref ? ref_input_next_event(e, ms) : input_next_event(e, ms); }

static void events(void)
{
    for (int i = 0; i < 100000; i++) {
        Event e;
        for (size_t k = 0; k < sizeof e; k++) ((uint8_t *)&e)[k] = 0xA5;        /* the parser must overwrite every field */
        int r = next(&e, 200);
        num("r=", r);
        num("t=", e.type);
        num("m=", e.mods);
        hex("k=", (uint32_t)e.key);
        num("x=", e.mouse_x);
        num("y=", e.mouse_y);
        num("b=", e.mouse_btn);
        num("a=", e.mouse_kind);
        hex("l=", (uint32_t)e.lat);
        put("\n");
        if (g_n > sizeof g_out - 200) flush();
        if (r == -2) break;
    }
    num("eof=", g_ref ? ref_input_is_eof() : input_is_eof());
    caps();
}

static int read_all(uint8_t *buf, int cap)
{
    int n = 0;
    intptr_t r;
    while (n < cap && (r = os_read(0, buf + n, (size_t)(cap - n))) > 0) n += (int)r;
    return n;
}

static void filter(int from)
{
    static uint8_t buf[8192];
    int n = read_all(buf, sizeof buf);
    if (from > n) from = n;
    int removed = g_ref ? ref_term_caps_filter(buf, from, n) : term_caps_filter(buf, from, n);
    num("removed=", removed);
    put("left=");
    for (int i = 0; i < n - removed; i++) hex("", buf[i]);
    put("\n");
    caps();
}

static void aux(int ms)
{
    int p[2];
    (void)os_pipe_cloexec(p);
    (void)os_write(p[1], "x", 1);
    if (g_ref) ref_input_set_aux_fd(0, p[0]); else input_set_aux_fd(0, p[0]);
    Event e;
    int64_t t0 = os_clock_ms();
    int r = next(&e, ms);
    num("aux_r=", r);
    num("aux_fast=", os_clock_ms() - t0 < 300);
    if (g_ref) ref_input_set_aux_fd(0, -1); else input_set_aux_fd(0, -1);      /* the fd is gone: the wait is the full timeout */
    t0 = os_clock_ms();
    r = next(&e, 120);
    num("none_r=", r);
    num("none_waited=", os_clock_ms() - t0 >= 100);
    put("\n");
}

static void init(char **envp)
{
    static const uint8_t da1[] = "\x1b[?62;4;22c";
    static uint8_t buf[16];
    if (g_ref) ref_term_caps_init(envp); else term_caps_init(envp);
    caps();
    for (size_t i = 0; i < sizeof da1; i++) buf[i] = da1[i];
    (void)(g_ref ? ref_term_caps_filter(buf, 0, (int)sizeof da1 - 1) : term_caps_filter(buf, 0, (int)sizeof da1 - 1));
    caps();
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 3) return 2;
    g_ref = !str_cmp(argv[1], "ref");
    const char *mode = argv[2];
    long a = 0, b = 0;
    for (const char *s = argc > 3 ? argv[3] : ""; *s >= '0' && *s <= '9'; s++) a = a * 10 + (*s - '0');
    for (const char *s = argc > 4 ? argv[4] : ""; *s >= '0' && *s <= '9'; s++) b = b * 10 + (*s - '0');
    if (!str_cmp(mode, "events")) events();
    else if (!str_cmp(mode, "filter")) filter((int)a);
    else if (!str_cmp(mode, "init")) init(envp);
    else if (!str_cmp(mode, "aux")) aux((int)a);
    else if (!str_cmp(mode, "winch")) {
        g_sigwinch = 1;
        Event e;
        num("r=", next(&e, 0));
        num("t=", e.type);
        num("again=", g_sigwinch);
        put("\n");
    } else if (!str_cmp(mode, "probe")) num("eof=", g_ref ? ref_input_probe_eof() : input_probe_eof());
    else if (!str_cmp(mode, "uint")) {
        const char *s = argc > 3 ? argv[3] : "";
        hex("v=", g_ref ? ref_parse_uint(s) : parse_uint(s));
    } else if (!str_cmp(mode, "refresh")) {
        static uint8_t reply[] = "\x1b[6;20;10t";
        if (g_ref) { (void)ref_term_caps_filter(reply, 0, (int)sizeof reply - 1); ref_term_caps_refresh((int)a, (int)b); }
        else { (void)term_caps_filter(reply, 0, (int)sizeof reply - 1); term_caps_refresh((int)a, (int)b); }
        caps();
    }
    flush();
    return 0;
}
