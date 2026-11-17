/* Freestanding harness: the frozen asm preview reader (preview_io_reference.s + preview_helper_reference.s, x86_64, ref_ prefix)
 * or src/fs/preview_io.c + preview_helper.c; argv[1] = ref | c, one implementation per process (helper pid, pipes, sequence and
 * the shared buffer are global). pkg_preview_try is a stand-in: "PKG:<x>" yields a listing, a path containing "STUCK" sleeps 5 s
 * (a helper hung on dead storage), anything else is no package. Script on stdin:
 *   T <path> <w> <h> <proto> <cols> <bg hex> <cap> <off>   pv_make_thumb on the file head (32 KiB), out at offset off of a guard
 *                                                         buffer; prints the result and a hash of the whole buffer
 *   Q <path> <w> <h> <proto> <cols> <bg hex>               fs_preview_request; prints the sequence number
 *   W <cap>                                                waits (<= 3 s) for one reply: seq, err, len, head hash, tlen, payload hash
 *   S                                                      fs_preview_stop;    Z <ms>  sleep;    F  whether a reply fd exists
 *   C                                                      how many different helper processes have existed so far */
#include "script_cli.h"
#include "duop_preview.h"
#include "duop_pal.h"

#ifdef __x86_64__
extern size_t ref_pv_make_thumb(const char *, const uint8_t *, size_t, const PvThumbReq *, uint8_t *, size_t);
extern int ref_fs_preview_request(const char *, uint32_t, uint32_t, uint32_t);
extern int ref_fs_preview_fd(void);
extern int ref_fs_preview_receive(void *, size_t, uint32_t *, size_t *, size_t *);
extern void ref_fs_preview_stop(void);
extern uint8_t *ref_fs_preview_shm_slot(uint32_t);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static uint8_t g_head[PREVIEW_BUF_SIZE], g_out[IMG_THUMB_CAP + 4096], g_buf[PREVIEW_BUF_SIZE + 64];

int pkg_preview_try(char **envp, const char *path, char *out, int max_len)
{
    (void)envp;
    if (str_starts_with(path, "PKG:")) return (int)str_copy(out, "package listing of ", (size_t)max_len) + (int)str_copy(out + 19, path + 4, (size_t)max_len - 19);
    for (const char *p = path; *p; p++)
        if (str_starts_with(p, "STUCK")) { (void)os_poll_in(-1, 5000); break; }
    return -1;
}

static uint64_t fnv(const uint8_t *p, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

static void put_hex(uint64_t v)
{
    char t[17];
    for (int i = 15; i >= 0; i--, v >>= 4) t[i] = "0123456789abcdef"[v & 15];
    t[16] = 0;
    sc_put(t);
}

static int sc_split(char *line, char **f, int max)
{
    int n = 0;
    while (*line && n < max) {
        while (*line == ' ') *line++ = 0;
        if (!*line) break;
        f[n++] = line;
        while (*line && *line != ' ') line++;
    }
    return n;
}

static uint64_t num(const char *s, int base)
{
    uint64_t v = 0;
    for (;; s++) {
        int d = *s >= '0' && *s <= '9' ? *s - '0' : *s >= 'a' && *s <= 'f' ? *s - 'a' + 10 : -1;
        if (d < 0 || d >= base) return v;
        v = v * (uint64_t)base + (uint64_t)d;
    }
}

static PvThumbReq treq(char **f)
{
    return (PvThumbReq){.w = (uint16_t)num(f[2], 10), .h = (uint16_t)num(f[3], 10), .proto = (uint8_t)num(f[4], 10),
                        .cols = (uint8_t)num(f[5], 10), .bg = (uint32_t)num(f[6], 16)};
}

static void cmd_thumb(char **f, int n)
{
    if (n < 9) return;
    PvThumbReq rq = treq(f);
    size_t cap = num(f[7], 10), off = num(f[8], 10) & 7, len = 0;
    if (cap > IMG_THUMB_CAP + 2048) cap = IMG_THUMB_CAP + 2048;
    intptr_t fd = os_openat(AT_FDCWD, f[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd >= 0) {
        intptr_t r = os_read((int)fd, g_head, sizeof g_head);
        len = r > 0 ? (size_t)r : 0;
        (void)os_close((int)fd);
    }
    for (size_t i = 0; i < sizeof g_out; i++) g_out[i] = 0xA5;
    size_t r = CALL(pv_make_thumb, f[1], g_head, len, &rq, g_out + off, cap);
    sc_put("T r="); sc_num((int64_t)r); sc_put(" hdr=");
    put_hex(load_le64(g_out + off)); put_hex(load_le64(g_out + off + 8));
    sc_put(" buf="); put_hex(fnv(g_out, sizeof g_out));
}

static int g_seen[64], g_nseen;

static void cmd_children(void)                                    /* /proc/self/task/<pid>/children: the live helper */
{
    char path[64] = "/proc/self/task/", t[24], buf[256];
    size_t k = u64_to_dec((uint64_t)os_getpid(), t), n = 16;
    for (size_t i = 0; i < k; i++) path[n++] = t[i];
    (void)str_copy(path + n, "/children", 16);
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0), r = 0;
    if (fd >= 0) { r = os_read((int)fd, buf, sizeof buf - 1); (void)os_close((int)fd); }
    int pid = 0;
    for (intptr_t i = 0; i < r && buf[i] >= '0' && buf[i] <= '9'; i++) pid = pid * 10 + (buf[i] - '0');
    bool known = !pid;
    for (int i = 0; i < g_nseen; i++) known |= g_seen[i] == pid;
    if (!known && g_nseen < 64) g_seen[g_nseen++] = pid;
    sc_put("C "); sc_num(g_nseen); sc_put(pid ? " live" : " none");
}

static void cmd_wait(char **f, int n)
{
    size_t cap = n > 1 ? num(f[1], 10) : PREVIEW_BUF_SIZE;
    if (cap > sizeof g_buf) cap = sizeof g_buf;
    for (int tries = 0; tries < 300; tries++) {
        int fd = CALL(fs_preview_fd);
        if (fd < 0) { sc_put("W nofd"); return; }
        (void)os_poll_in(fd, 10);
        uint32_t seq = 0;
        size_t len = 0, tlen = 0;
        for (size_t i = 0; i < sizeof g_buf; i++) g_buf[i] = 0x5A;
        if (!CALL(fs_preview_receive, g_buf, cap, &seq, &len, &tlen)) continue;
        uint8_t *slot = CALL(fs_preview_shm_slot, seq);
        sc_put("W seq="); sc_num(seq); sc_put(" len="); sc_num((int64_t)len); sc_put(" head="); put_hex(fnv(g_buf, len));
        sc_put(" tail="); put_hex(fnv(g_buf + len, sizeof g_buf - len));
        sc_put(" tlen="); sc_num((int64_t)tlen); sc_put(" thumb="); put_hex(slot && tlen <= PV_SHM_SLOT_SZ ? fnv(slot, tlen) : 0);
        return;
    }
    sc_put("W none");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_envp = envp;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[10];
        int n = sc_split(line, f, 10);
        if (!n) continue;
        switch (f[0][0]) {
        case 'T': cmd_thumb(f, n); break;
        case 'Q': if (n >= 7) { PvThumbReq rq = treq(f); sc_put("Q "); sc_num(CALL(fs_preview_request, f[1], load_le32(&rq), load_le32(&rq.proto), rq.bg)); } break;
        case 'W': cmd_wait(f, n); break;
        case 'S': CALL(fs_preview_stop); sc_put("S"); break;
        case 'Z': (void)os_poll_in(-1, n > 1 ? (int)num(f[1], 10) : 0); sc_put("Z"); break;
        case 'F': sc_put("F "); sc_num(CALL(fs_preview_fd) >= 0); break;
        case 'C': cmd_children(); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    CALL(fs_preview_stop);
    sc_flush();
    return 0;
}
