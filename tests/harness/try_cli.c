/* Freestanding harness for the C TRY/CATCH fault guard (os_try_begin / os_try_end, pal_fault.s on both ISAs).
 * Commands on stdin, one per line; each result is a text line:
 *   S            write to a PROT_NONE page inside a TRY               -> "S sig=11 chain=0"
 *   K <sig>      raise <sig> (7 BUS, 8 FPE, 11 SEGV) on this thread in a TRY    -> "K <sig> sig=<sig> chain=0"
 *   N            nested TRYs: the inner one catches a fault, then a second fault is caught by the outer one
 *   E            a TRY that completes without a fault leaves no frame behind
 *   R            callee-saved registers are restored by the fault resume (assembly probe)
 *   M            (x86_64) an assembly TRY_BEGIN frame and a C frame share one chain
 *   X            a fault outside any TRY is fatal (the process dies with SIGSEGV)
 *   F            a fault in a forked child after os_mark_child_forked() is caught too */
#include "script_cli.h"
#include "duop_pal.h"

#define SIGBUS_ 7
#define SIGSEGV_ 11

int try_regs_probe(TryFrame *frame, volatile char *bad);        /* tests/harness/try_regs_<arch>.s */
#ifdef __x86_64__
int try_mix_probe(volatile char *bad);                           /* tests/harness/try_mix_x86_64.s */
#endif

static volatile char *g_bad;                                     /* a PROT_NONE page */

/* the signal that interrupted `*p = 1` inside a TRY, or 0 */
static int try_write(volatile char *p)
{
    TryFrame f;
    int sig = os_try_begin(&f);
    if (sig == 0) {
        *p = 1;
        os_try_end(&f);
    }
    return sig;
}

#ifdef __x86_64__
int try_mix_c(volatile char *bad);
int try_mix_c(volatile char *bad) { return try_write(bad); }
#endif

static int try_signal(int sig)
{
    TryFrame f;
    int got = os_try_begin(&f);
    if (got == 0) {
        (void)os_tgkill((int)os_getpid(), (int)os_gettid(), sig);
        os_try_end(&f);
    }
    return got;
}

static void chain(const char *what, int sig)
{
    sc_put(what); sc_put(" sig="); sc_num(sig); sc_put(" chain="); sc_num(g_try_frame != nullptr); sc_put("\n");
}

static void nested(void)
{
    TryFrame outer;
    volatile int inner_sig = -1, outer_sig = -1;
    int o = os_try_begin(&outer);
    if (o == 0) {
        TryFrame inner;
        int i = os_try_begin(&inner);
        if (i == 0) {
            *g_bad = 1;
            os_try_end(&inner);
        }
        inner_sig = i;                                            /* the handler unlinked `inner`: the chain is `outer` again */
        sc_put("N inner chain_is_outer="); sc_num(g_try_frame == &outer); sc_put("\n");
        *g_bad = 1;                                               /* now the outer frame must catch */
        os_try_end(&outer);
    } else {
        outer_sig = o;
    }
    sc_put("N inner="); sc_num(inner_sig); sc_put(" outer="); sc_num(outer_sig); sc_put(" chain="); sc_num(g_try_frame != nullptr); sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    os_fault_guard_install();
    intptr_t page = os_mmap(nullptr, 4096, 0 /* PROT_NONE */, MAP_PRIVATE_ANON, -1, 0);
    if (os_is_err(page)) return 3;
    g_bad = (volatile char *)page;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        uint64_t arg = 0;
        sc_dec(line + 1, &arg);
        switch (line[0]) {
        case 'S': chain("S", try_write(g_bad)); break;
        case 'K': sc_put("K"); sc_num((int64_t)arg); chain("", try_signal((int)arg)); break;
        case 'N': nested(); break;
        case 'E': { TryFrame f; int s = os_try_begin(&f); if (s == 0) os_try_end(&f); chain("E", s); break; }
        case 'R': { TryFrame f; sc_put("R probe="); sc_num(try_regs_probe(&f, g_bad)); sc_put("\n"); break; }
#ifdef __x86_64__
        case 'M': sc_put("M mix="); sc_num(try_mix_probe(g_bad)); sc_put("\n"); break;
#endif
        case 'F': {
            intptr_t pid = os_fork();
            if (pid == 0) {
                os_mark_child_forked();
                os_exit(try_write(g_bad) == SIGSEGV_ ? 42 : 43);
            }
            int status = -1;
            (void)os_wait4((int)pid, &status, 0, nullptr);
            sc_put("F child_exit="); sc_num((status >> 8) & 0xff); sc_put(" signaled="); sc_num(status & 0x7f); sc_put("\n");
            break;
        }
        case 'X': sc_flush(); *g_bad = 1; break;
        default: break;
        }
    }
    sc_flush();
    (void)SIGBUS_;
    return 0;
}
