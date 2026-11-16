// faultlab -- ptrace fault injector for static zero-libc x86-64 Linux binaries (Duop).
//
//   faultlab -o report [-r RULE]... -- prog args...
//
// RULE = kind:scope:sys:k:n:val[:fdsel]
//   kind  e  errno injection   -- the k-th matching syscall (1-based) is skipped, returns -val
//         s  short I/O         -- the byte count (rdx) of the k-th read/write is clamped to val
//         f  bit flip (SEU)    -- after the k-th matching syscall returns, one bit is flipped;
//                                 val = seed, fdsel field = target: reg|stack|bss|heap|text
//   scope u  UI process (the program started by faultlab, threads included)
//         c  forked copies of the program (background workers, helpers before exec)
//         a  both
//   sys   syscall number        n  how many consecutive matches are hit (0 = every later one)
//   fdsel any|tty|file         (e/s only) restrict to calls whose first argument is such an fd
//
// The report (key=value lines) holds the exit status, every fatal signal seen (with rip / fault
// address), applied injections, per-role syscall counts and -- on SIGTERM (driver timeout) --
// where each task is blocked. Programs exec'ed by the target are followed but never injected.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/user.h>
#include <sys/wait.h>

#define MAXT 512
#define MAXR 16
#define NSYS 512
enum { R_UI = 0, R_CHILD = 1, R_FOREIGN = 2 };

struct proc { pid_t tgid; int role, refs; long rc[MAXR]; };
struct task { pid_t tid; int used, startup, parked, inj, flip; long inj_ret; struct proc *p; };
struct rule { char kind, scope; int sys; long k, n, val; char sel[8]; long hits; };

static struct task T[MAXT];
static struct proc P[MAXT];
static struct rule R[MAXR];
static int nrules;
static long counts[2][NSYS];
static FILE *rep;
static pid_t root;
static volatile sig_atomic_t g_term, g_alarm;
static uint64_t rng;

static void on_term(int s) { (void)s; g_term = 1; }
static void on_alarm(int s) { (void)s; g_alarm = 1; }

static uint64_t rnd(void) {                       // xorshift64*
    rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
    return rng * 0x2545F4914F6CDD1DULL;
}

static pid_t tgid_of(pid_t tid) {
    char path[64], line[256];
    snprintf(path, sizeof path, "/proc/%d/status", tid);
    FILE *f = fopen(path, "r");
    pid_t tg = tid;
    if (!f) return tg;
    while (fgets(line, sizeof line, f))
        if (!strncmp(line, "Tgid:", 5)) { tg = atoi(line + 5); break; }
    fclose(f);
    return tg;
}

static struct task *find_task(pid_t tid) {
    for (int i = 0; i < MAXT; i++) if (T[i].used && T[i].tid == tid) return &T[i];
    return NULL;
}

static struct proc *proc_for(pid_t tgid, int role) {
    struct proc *slot = NULL;
    for (int i = 0; i < MAXT; i++) {
        if (P[i].refs && P[i].tgid == tgid) return &P[i];
        if (!P[i].refs && !slot) slot = &P[i];
    }
    if (!slot) { fprintf(stderr, "faultlab: process table full\n"); exit(2); }
    memset(slot, 0, sizeof *slot);
    slot->tgid = tgid; slot->role = role;
    return slot;
}

static struct task *add_task(pid_t tid, int role) {
    for (int i = 0; i < MAXT; i++) if (!T[i].used) {
        memset(&T[i], 0, sizeof T[i]);
        T[i].used = 1; T[i].tid = tid; T[i].flip = -1;
        T[i].p = proc_for(tgid_of(tid), role);
        T[i].p->refs++;
        return &T[i];
    }
    fprintf(stderr, "faultlab: task table full\n"); exit(2);
}

static void del_task(struct task *t) { t->p->refs--; t->used = 0; }

static int fd_is_tty(pid_t pid, long fd) {
    char path[64], buf[128];
    snprintf(path, sizeof path, "/proc/%d/fd/%ld", pid, fd);
    ssize_t n = readlink(path, buf, sizeof buf - 1);
    if (n <= 0) return 0;
    buf[n] = 0;
    return !strncmp(buf, "/dev/pts/", 9) || !strncmp(buf, "/dev/tty", 8);
}

// ---- SEU targets -------------------------------------------------------------------------
static int page_present(int pm, uint64_t addr) {
    uint64_t e = 0;
    if (pread(pm, &e, 8, (off_t)(addr / 4096 * 8)) != 8) return 0;
    return (int)(e >> 63);
}

// Pick a random byte of a touched (resident) page of the wanted mapping class.
static uint64_t pick_addr(pid_t pid, const char *cls) {
    char path[64], line[512];
    uint64_t lo[256], hi[256], total = 0;
    int n = 0;
    snprintf(path, sizeof path, "/proc/%d/maps", pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    while (n < 256 && fgets(line, sizeof line, f)) {
        unsigned long a, b; char perm[8], name[256] = "";
        if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %255s", &a, &b, perm, name) < 3) continue;
        int is_bss = perm[1] == 'w' && a < 0x10000000UL;
        int is_text = perm[2] == 'x' && a < 0x10000000UL;
        int is_heap = perm[1] == 'w' && a >= 0x10000000UL && name[0] != '[';
        if ((!strcmp(cls, "bss") && is_bss) || (!strcmp(cls, "text") && is_text) ||
            (!strcmp(cls, "heap") && is_heap)) {
            lo[n] = a; hi[n] = b; total += b - a; n++;
        }
    }
    fclose(f);
    if (!total) return 0;
    snprintf(path, sizeof path, "/proc/%d/pagemap", pid);
    int pm = open(path, O_RDONLY);
    uint64_t addr = 0;
    for (int tries = 0; tries < 4096; tries++) {
        uint64_t off = rnd() % total;
        for (int i = 0; i < n; i++) {
            if (off < hi[i] - lo[i]) { addr = lo[i] + off; break; }
            off -= hi[i] - lo[i];
        }
        if (pm < 0 || page_present(pm, addr)) break;
        addr = 0;
    }
    if (pm >= 0) close(pm);
    return addr;
}

static void flip_mem(pid_t pid, uint64_t addr, const char *cls) {
    int bit = (int)(rnd() % 8);
    uint64_t al = addr & ~7ULL;
    errno = 0;
    long w = ptrace(PTRACE_PEEKDATA, pid, (void *)al, 0);
    if (errno) { fprintf(rep, "seu=failed peek %s 0x%lx\n", cls, (unsigned long)addr); return; }
    w ^= 1L << ((addr & 7) * 8 + bit);
    ptrace(PTRACE_POKEDATA, pid, (void *)al, (void *)w);
    fprintf(rep, "seu=%s addr=0x%lx bit=%d\n", cls, (unsigned long)addr, bit);
}

static void do_flip(struct task *t, struct rule *r) {
    struct user_regs_struct g;
    if (ptrace(PTRACE_GETREGS, t->tid, 0, &g)) return;
    rng = (uint64_t)r->val * 0x9E3779B97F4A7C15ULL + 0x1234567;
    rnd(); rnd();
    if (!strcmp(r->sel, "reg")) {
        static const char *nm[] = { "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8",
                                    "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip" };
        unsigned long long *pp[] = { &g.rax, &g.rbx, &g.rcx, &g.rdx, &g.rsi, &g.rdi, &g.rbp,
                                     &g.rsp, &g.r8, &g.r9, &g.r10, &g.r11, &g.r12, &g.r13,
                                     &g.r14, &g.r15, &g.rip };
        int i = (int)(rnd() % 17), bit = (int)(rnd() % 64);
        *pp[i] ^= 1ULL << bit;
        ptrace(PTRACE_SETREGS, t->tid, 0, &g);
        fprintf(rep, "seu=reg name=%s bit=%d rip=0x%llx\n", nm[i], bit, g.rip);
    } else if (!strcmp(r->sel, "stack")) {
        flip_mem(t->tid, g.rsp + rnd() % 512, "stack");
    } else {
        uint64_t a = pick_addr(t->tid, r->sel);
        if (a) flip_mem(t->tid, a, r->sel);
        else fprintf(rep, "seu=failed no %s page\n", r->sel);
    }
    r->hits++;
}

// ---- syscall stops -----------------------------------------------------------------------
static void on_syscall(struct task *t) {
    struct __ptrace_syscall_info si;
    struct user_regs_struct g;
    if (t->p->role > R_CHILD) return;
    if (ptrace(PTRACE_GET_SYSCALL_INFO, t->tid, (void *)sizeof si, &si) <= 0) return;
    if (si.op == PTRACE_SYSCALL_INFO_ENTRY) {
        long nr = (long)si.entry.nr;
        int role = t->p->role;
        if (nr >= 0 && nr < NSYS) counts[role][nr]++;
        for (int i = 0; i < nrules; i++) {
            struct rule *r = &R[i];
            if (r->sys != nr) continue;
            if (!(r->scope == 'a' || (r->scope == 'u' && role == R_UI) ||
                  (r->scope == 'c' && role == R_CHILD))) continue;
            if (r->kind != 'f' && strcmp(r->sel, "any")) {
                int tty = fd_is_tty(t->tid, (long)si.entry.args[0]);
                if (tty != !strcmp(r->sel, "tty")) continue;
            }
            long c = ++t->p->rc[i];
            if (c < r->k || (r->n && c >= r->k + r->n)) continue;
            if (r->kind == 'f') { if (!r->hits) t->flip = i; continue; }
            if (ptrace(PTRACE_GETREGS, t->tid, 0, &g)) continue;
            if (r->kind == 'e') {
                g.orig_rax = (unsigned long long)-1;
                t->inj = 1; t->inj_ret = -r->val;
            } else if (g.rdx > (unsigned long long)r->val) {
                g.rdx = (unsigned long long)r->val;
            } else continue;
            ptrace(PTRACE_SETREGS, t->tid, 0, &g);
            if (r->hits++ < 4)
                fprintf(rep, "hit=%c role=%d sys=%ld occ=%ld rip=0x%llx\n", r->kind, role, nr, c, g.rip);
        }
    } else if (si.op == PTRACE_SYSCALL_INFO_EXIT) {
        if (t->inj) {
            t->inj = 0;
            if (!ptrace(PTRACE_GETREGS, t->tid, 0, &g)) {
                g.rax = (unsigned long long)t->inj_ret;
                ptrace(PTRACE_SETREGS, t->tid, 0, &g);
            }
        }
        if (t->flip >= 0) { do_flip(t, &R[t->flip]); t->flip = -1; }
    }
}

static int nfatal;
static void on_signal(struct task *t, int sig) {
    if (t->p->role == R_FOREIGN || nfatal >= 12) return;
    if (sig != SIGSEGV && sig != SIGBUS && sig != SIGFPE && sig != SIGILL && sig != SIGABRT &&
        sig != SIGTRAP && sig != SIGSYS) return;
    struct user_regs_struct g; siginfo_t si;
    memset(&g, 0, sizeof g); memset(&si, 0, sizeof si);
    ptrace(PTRACE_GETREGS, t->tid, 0, &g);
    ptrace(PTRACE_GETSIGINFO, t->tid, 0, &si);
    fprintf(rep, "fault=%d role=%d rip=0x%llx rsp=0x%llx addr=0x%lx code=%d\n", sig, t->p->role,
            g.rip, g.rsp, (unsigned long)si.si_addr, si.si_code);
    nfatal++;
}

static void resume(struct task *t, int sig) {
    ptrace(t->p->role == R_FOREIGN ? PTRACE_CONT : PTRACE_SYSCALL, t->tid, 0, (void *)(long)sig);
}

static void dump_blocked(void) {
    for (int i = 0; i < MAXT; i++) {
        if (!T[i].used || T[i].p->role == R_FOREIGN) continue;
        char path[64], buf[256] = "";
        snprintf(path, sizeof path, "/proc/%d/syscall", T[i].tid);
        FILE *f = fopen(path, "r");
        if (f) { if (!fgets(buf, sizeof buf, f)) buf[0] = 0; fclose(f); }
        buf[strcspn(buf, "\n")] = 0;
        fprintf(rep, "blocked=role%d tid=%d syscall=%s\n", T[i].p->role, T[i].tid, buf);
    }
}

static int parse_rule(const char *s, struct rule *r) {
    char sel[16] = "any";
    memset(r, 0, sizeof *r);
    int n = sscanf(s, "%c:%c:%d:%ld:%ld:%ld:%15s", &r->kind, &r->scope, &r->sys, &r->k, &r->n,
                   &r->val, sel);
    if (n < 6 || !strchr("esf", r->kind) || !strchr("uca", r->scope)) return -1;
    snprintf(r->sel, sizeof r->sel, "%s", sel);
    return 0;
}

int main(int argc, char **argv) {
    const char *out = NULL;
    int ai = 1;
    for (; ai < argc && strcmp(argv[ai], "--"); ai++) {
        if (!strcmp(argv[ai], "-o") && ai + 1 < argc) out = argv[++ai];
        else if (!strcmp(argv[ai], "-r") && ai + 1 < argc && nrules < MAXR) {
            if (parse_rule(argv[++ai], &R[nrules++])) { fprintf(stderr, "bad rule\n"); return 2; }
        } else { fprintf(stderr, "usage: faultlab -o report [-r rule]... -- prog args\n"); return 2; }
    }
    if (ai + 1 >= argc || !out) { fprintf(stderr, "usage: faultlab -o report [-r rule]... -- prog args\n"); return 2; }
    rep = fopen(out, "w");
    if (!rep) { perror(out); return 2; }
    setvbuf(rep, NULL, _IOLBF, 0);

    struct sigaction sa = { 0 };
    sa.sa_handler = on_term; sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_alarm; sigaction(SIGALRM, &sa, NULL);

    root = fork();
    if (root == 0) {
        ptrace(PTRACE_TRACEME, 0, 0, 0);
        raise(SIGSTOP);
        execv(argv[ai + 1], argv + ai + 1);
        _exit(127);
    }
    int st;
    waitpid(root, &st, 0);
    ptrace(PTRACE_SETOPTIONS, root, 0, (void *)(long)(PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACEFORK |
           PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL));
    struct task *rt = add_task(root, R_FOREIGN);   // becomes R_UI at its exec event
    resume(rt, 0);

    int root_status = -1, root_done = 0;
    for (;;) {
        pid_t pid = waitpid(-1, &st, __WALL);
        if (pid < 0) {
            if (errno == EINTR) {
                if (g_term) { fprintf(rep, "hang=1\n"); dump_blocked(); break; }
                if (g_alarm) {
                    int left = 0;
                    for (int i = 0; i < MAXT; i++) left += T[i].used;
                    fprintf(rep, "orphans=%d\n", left);
                    break;
                }
                continue;
            }
            break;                                 // ECHILD: everything exited
        }
        struct task *t = find_task(pid);
        if (WIFEXITED(st) || WIFSIGNALED(st)) {
            if (pid == root) { root_status = st; root_done = 1; alarm(2); }
            if (t) del_task(t);
            continue;
        }
        if (!WIFSTOPPED(st)) continue;
        int sig = WSTOPSIG(st), ev = st >> 16;
        if (!t) {                                  // child seen before its parent's fork event
            t = add_task(pid, R_FOREIGN);
            t->parked = 1; t->startup = 1;
            continue;
        }
        if (sig == (SIGTRAP | 0x80)) { on_syscall(t); resume(t, 0); continue; }
        if (ev == PTRACE_EVENT_FORK || ev == PTRACE_EVENT_VFORK || ev == PTRACE_EVENT_CLONE) {
            unsigned long cpid = 0;
            ptrace(PTRACE_GETEVENTMSG, pid, 0, &cpid);
            int role = t->p->role == R_UI && ev != PTRACE_EVENT_CLONE ? R_CHILD : t->p->role;
            struct task *c = find_task((pid_t)cpid);
            if (c) {                               // already stopped and parked: fix role, go
                if (ev != PTRACE_EVENT_CLONE) c->p->role = role;
                else { c->p->refs--; c->p = t->p; c->p->refs++; }
                c->startup = 0; c->parked = 0;
                resume(c, 0);
            } else {
                c = add_task((pid_t)cpid, role);
                if (ev == PTRACE_EVENT_CLONE && c->p != t->p) { c->p->refs--; c->p = t->p; c->p->refs++; }
                c->startup = 1;
            }
            resume(t, 0);
            continue;
        }
        if (ev == PTRACE_EVENT_EXEC) {
            t->p->role = pid == root && t->p->role == R_FOREIGN && !root_done ? R_UI : R_FOREIGN;
            if (pid != root) t->p->role = R_FOREIGN;
            resume(t, 0);
            continue;
        }
        if (ev) { resume(t, 0); continue; }
        if (t->startup && sig == SIGSTOP) { t->startup = 0; resume(t, 0); continue; }
        on_signal(t, sig);
        resume(t, sig);
    }

    for (int role = 0; role < 2; role++)
        for (int i = 0; i < NSYS; i++)
            if (counts[role][i]) fprintf(rep, "count.%s.%d=%ld\n", role ? "child" : "ui", i, counts[role][i]);
    for (int i = 0; i < nrules; i++) fprintf(rep, "rule%d.hits=%ld\n", i, R[i].hits);
    int code = 255;
    if (root_done) {
        if (WIFEXITED(root_status)) { code = WEXITSTATUS(root_status); fprintf(rep, "exit=%d\n", code); }
        else { code = 128 + WTERMSIG(root_status); fprintf(rep, "killed=%d\n", WTERMSIG(root_status)); }
    }
    fclose(rep);
    for (int i = 0; i < MAXT; i++) if (T[i].used) kill(T[i].tid, SIGKILL);
    return code;
}
