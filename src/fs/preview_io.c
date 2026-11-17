/* src/fs/preview_io.c - asynchronous preview reader, UI side (freestanding C23; replaces preview_io.s, kept as
 * tests/harness/preview_io_reference.s).
 *
 * The UI never touches the disk for previews: it writes {seq, path, thumb request} into a non-blocking pipe and receives
 * {seq, err, len, tlen, data[len]} replies (an image's thumbnail payload, tlen bytes, lands in a shared ping-pong slot) on a pipe
 * the event loop polls. A helper stuck on a dead filesystem is killed and respawned after PV_STUCK_MS, so the UI stays responsive
 * whatever the storage does; replies to older requests are told apart by their sequence number. */
#include "duop_preview.h"
#include "duop_pal.h"
#include "duop_string.h"

#define PV_HDR 16              /* reply: u32 seq, i32 err, u32 len, u32 thumb len */
#define PV_REQ 20              /* request: u32 seq, path len, dims, mode, bg */

static int64_t g_pv_sent_ms;
static int g_pv_pipes[4];      /* req[0..1], resp[2..3] while starting */
static int g_pv_pid;
static int g_pv_req1, g_pv_resp1;   /* request write end + 1, reply read end + 1 (0 = none) */
static uint32_t g_pv_seq;      /* last issued sequence number */
static int g_pv_busy;          /* a request for g_pv_seq is outstanding */
static uint8_t *g_pv_shm;      /* MAP_SHARED buffer the helper writes image payloads into */

intptr_t pv_read_exact(int fd, void *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        intptr_t r = os_read(fd, (uint8_t *)buf + got, n - got);
        if (r == -EINTR) continue;
        if (r == -EAGAIN) {
            int p;
            while ((p = os_poll_in(fd, 200)) == -EINTR) {}
            if (p > 0) continue;
            return -EIO;                                 /* writer stalled mid-message */
        }
        if (r <= 0) return r;
        got += (size_t)r;
    }
    return (intptr_t)got;
}

static void pv_close(int fd) { (void)os_close(fd); }

static void pv_kill_reap(int pid)
{
    int status;
    (void)os_kill(pid, SIGKILL);
    while (os_wait4(pid, &status, 0, nullptr) == -EINTR) {}
}

/* the parent's half after fork: keep the request write end and the reply read end, both non-blocking */
static intptr_t pv_setup_parent_pipes(int pid)
{
    g_pv_pid = pid;
    pv_close(g_pv_pipes[0]);                             /* fault-checked: unused pipe end in parent */
    pv_close(g_pv_pipes[3]);                             /* fault-checked: unused pipe end in parent */
    int r = os_set_nonblock(g_pv_pipes[1]);
    if (r >= 0) r = os_set_nonblock(g_pv_pipes[2]);
    if (r < 0) {
        pv_close(g_pv_pipes[1]);
        pv_close(g_pv_pipes[2]);
        if (g_pv_pid) pv_kill_reap(g_pv_pid);
        g_pv_pid = 0;
        return r;
    }
    g_pv_req1 = g_pv_pipes[1] + 1;
    g_pv_resp1 = g_pv_pipes[2] + 1;
    g_pv_busy = 0;
    return 0;
}

[[noreturn]] static void pv_child(int ppid)
{
    os_mark_child_forked();
    os_uring_atfork_reset();
    if (!os_set_pdeathsig(ppid, SIGKILL)) os_exit(0);   /* fault-checked: exit if the UI already died */
    pv_close(g_pv_pipes[1]);
    pv_close(g_pv_pipes[2]);
    pv_helper_main(g_pv_pipes[0], g_pv_pipes[3]);
}

/* 0 or -errno */
static intptr_t pv_start(void)
{
    if (!g_pv_shm) {                                     /* shared with every helper forked from now on */
        intptr_t m = os_mmap(nullptr, PV_SHM_CAP, PROT_RW, MAP_SHARED_ANON, -1, 0);
        if (m >= 0 || m < -4095) g_pv_shm = (uint8_t *)m;
    }
    intptr_t r = os_pipe_cloexec(&g_pv_pipes[0]);
    if (r < 0) return r;
    r = os_pipe_cloexec(&g_pv_pipes[2]);
    if (r >= 0) {
        int ppid = (int)os_getpid();                     /* fault-checked: getpid always succeeds */
        intptr_t pid = os_fork();
        if (pid == 0) pv_child(ppid);
        if (pid > 0) return pv_setup_parent_pipes((int)pid);
        r = pid;
        pv_close(g_pv_pipes[2]);
        pv_close(g_pv_pipes[3]);
    }
    pv_close(g_pv_pipes[0]);
    pv_close(g_pv_pipes[1]);
    return r;
}

void fs_preview_stop(void)
{
    if (!g_pv_pid) return;
    pv_close(g_pv_req1 - 1);
    pv_close(g_pv_resp1 - 1);
    pv_kill_reap(g_pv_pid);
    g_pv_pid = g_pv_req1 = g_pv_resp1 = g_pv_busy = 0;
}

uint8_t *fs_preview_shm(void) { return g_pv_shm; }

uint8_t *fs_preview_shm_slot(uint32_t seq) { return g_pv_shm ? g_pv_shm + (seq & 1) * (size_t)PV_SHM_SLOT_SZ : nullptr; }

int fs_preview_fd(void) { return g_pv_resp1 - 1; }

int fs_preview_request(const char *path, uint32_t dims, uint32_t mode, uint32_t bg)
{
    uint8_t msg[PV_REQ + PATH_MAX];
    int64_t now = os_clock_ms();
    if (g_pv_pid && g_pv_busy && (uint64_t)(now - g_pv_sent_ms) >= PV_STUCK_MS)
        fs_preview_stop();                               /* helper hung on dead storage: replace it */
    if (!g_pv_pid && pv_start() < 0) return -1;
    size_t len = str_len(path);
    if (len > PATH_MAX - 1) return -1;
    const uint32_t hdr[5] = {++g_pv_seq, (uint32_t)len, dims, mode, bg};
    mem_copy(msg, hdr, sizeof hdr);
    mem_copy(msg + PV_REQ, path, len);
    if (os_write(g_pv_req1 - 1, msg, len + PV_REQ) != (intptr_t)(len + PV_REQ)) {
        fs_preview_stop();                               /* pipe full / broken: the helper is not keeping up */
        return -1;
    }
    g_pv_busy = 1;
    g_pv_sent_ms = now;
    return (int)g_pv_seq;
}

int fs_preview_receive(void *buf, size_t cap, uint32_t *out_seq, size_t *out_len, size_t *out_tlen)
{
    int fd = g_pv_resp1 - 1;
    if (fd < 0) return 0;
    uint32_t hdr[4];
    intptr_t r = os_read(fd, hdr, PV_HDR);
    if (r == -EAGAIN || r == -EINTR) return 0;
    if (r > 0 && r < PV_HDR) r = pv_read_exact(fd, (uint8_t *)hdr + r, PV_HDR - (size_t)r);
    if (r <= 0) goto broken;                             /* 0 = EOF (helper dead) or a fatal read error */
    *out_len = hdr[2];
    if (out_tlen) *out_tlen = hdr[3];
    if (hdr[2] > cap) goto broken;
    if (hdr[2] && pv_read_exact(fd, buf, hdr[2]) <= 0) goto broken;
    *out_seq = hdr[0];
    if (hdr[0] == g_pv_seq) g_pv_busy = 0;
    return 1;
broken:
    fs_preview_stop();                                   /* desynchronized stream: restart on the next request */
    return 0;
}
