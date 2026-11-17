/* src/core/try_rt.c - runtime state and startup installer for the TRY/CATCH fault guard (replaces try_rt.s). */
#include "duop_sys.h"

void *g_try_frame;                      /* 8 bytes in .bss; the asm TRY macros read and write it by symbol */

/* Installs the unified SA_SIGINFO handler for SIGSEGV/SIGBUS/SIGFPE once at startup. */
void os_fault_guard_install(void)
{
    os_fault_guard_install_slot(&g_try_frame);
}
