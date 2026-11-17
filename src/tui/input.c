/* src/tui/input.c - input byte pump (freestanding C23; replaces input.s).
 *
 * Owns the raw stdin buffer in_buf[in_pos..in_len): wait_and_read() polls stdin (plus the registered wake fds), reads
 * what arrived, drops terminal replies (term_caps_filter) and leaves the rest to the key parser (input_parse.c,
 * input_seq.c). input_next_event() adds the layout-independent hotkey (Event.lat). */
#include "duop_pal.h"
#include "duop_sys.h"
#include "duop_tui.h"

uint8_t in_buf[IN_BUF_SIZE];
uint32_t in_pos, in_len;
static int32_t in_aux1[4];             /* auxiliary wake fds + 1 (0 = none): task pipe, dir watch, preview */
static int32_t g_stdin_eof;

int input_is_eof(void) { return g_stdin_eof; }

int input_probe_eof(void)
{
    wait_and_read_fd(0, 0);
    return g_stdin_eof;
}

int input_next_event(Event *evt, int timeout_ms)
{
    if (g_stdin_eof) return -2;
    int r = input_poll_event(evt, timeout_ms);
    evt->lat = evt->key;
    if (evt->type == EVT_KEY) evt->lat = kbd_latin(evt->key);
    return r;
}

/* Registers descriptors whose readability/hang-up ends the idle wait of input_poll_event early (returning "no
 * event"), so the app loop reacts to them instantly. */
void input_set_aux_fd(int slot, int fd) { in_aux1[slot & 3] = fd + 1; }

void input_set_wake_fd(int fd) { input_set_aux_fd(0, fd); }

uint64_t parse_uint(const char *p)
{
    const uint8_t *q = (const uint8_t *)p;
    return parse_uint_adv(&q);
}

int wait_and_read(int timeout_ms) { return wait_and_read_fd(timeout_ms, 0); }

/* Appends incoming bytes to in_buf (compacting first). Returns the bytes left for the key parser, 0 on timeout or when
 * only an aux fd fired (the app loop then runs its tick), -1 on EINTR, -2 on EOF / fatal. */
int wait_and_read_fd(int timeout_ms, int use_aux)
{
    if (in_pos < in_len) {
        if (in_pos) {
            in_len -= in_pos;
            mem_move(in_buf, in_buf + in_pos, in_len);
            in_pos = 0;
        }
    } else {
        in_pos = in_len = 0;
    }
    int fds[5] = {0, -1, -1, -1, -1};
    if (use_aux)
        for (int i = 0; i < 4; i++) fds[1 + i] = in_aux1[i] - 1;
    int ready = os_poll_many(fds, 5, timeout_ms);
    if (ready == -EINTR || ready == -ENOMEM) return -1;
    if (ready == -EAGAIN || ready == 0) return 0;
    if (ready < 0) return -2;
    if (!(ready & 1)) return 0;                      /* only an aux fd fired */
    if (in_len >= IN_BUF_SIZE) return 0;
    intptr_t n = sys_read_retry(0, in_buf + in_len, IN_BUF_SIZE - in_len);
    if (n < 0 && n == -EAGAIN) return 0;
    if (n <= 0) {
        g_stdin_eof = 1;
        return -2;
    }
    in_len += (uint32_t)n;
    int removed = term_caps_filter(in_buf, (int)(in_len - (uint32_t)n), (int)in_len);   /* replies never reach the parser */
    in_len -= (uint32_t)removed;
    return (int)n - removed;
}
