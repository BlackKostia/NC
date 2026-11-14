# src/fs/du_links.s - hard-link accounting for Disk Usage: a file with several names
# (st_nlink > 1) is counted once per scan, like `du`. A (dev, ino) set shared by the walker
# threads behind a spinlock; du_links_reset (main thread) allocates and clears it per scan.
.intel_syntax noprefix

.include "pal.inc"
.equ DL_CAP,    262144                # slots (power of two), 16 bytes each = 4 MiB
.equ DL_MASK,   DL_CAP - 1
.equ DL_PROBES, 64

.section .bss
.align 8
g_dl_tbl:   .space 8                  # {u64 ino, u64 dev} slots, ino 0 = free
g_dl_used:  .space 4                  # slots taken since the last reset
g_dl_lock:  .space 4

.section .text
.global du_links_reset
.global du_link_first
.global du_links_cleanup

.extern mem_alloc
.extern mem_free
.extern mem_zero

# void du_links_reset(void) -- empty set for a new scan (allocated on first use)
du_links_reset:
    push rbx
    mov rbx, [rip + g_dl_tbl]
    test rbx, rbx
    jnz .Llr_clear
    mov edi, DL_CAP * 16
    call mem_alloc
    test rax, rax
    jz .Llr_ret
    mov rbx, rax
    mov [rip + g_dl_tbl], rax
    mov dword ptr [rip + g_dl_used], 1  # fresh heap memory: clear it below
.Llr_clear:
    cmp dword ptr [rip + g_dl_used], 0
    je .Llr_ret
    mov rdi, rbx
    mov esi, DL_CAP * 16
    call mem_zero
    mov dword ptr [rip + g_dl_used], 0
.Llr_ret:
    pop rbx
    ret

# int du_link_first(uint64_t dev, uint64_t ino) -> 1 = first sighting (count it), 0 = seen before.
# Without a table or with a crowded probe run it answers 1: never undercount.
du_link_first:
    mov r8, [rip + g_dl_tbl]
    mov eax, 1
    test r8, r8
    jz .Llf_ret
.Llf_lock:
    mov eax, 1
    xchg [rip + g_dl_lock], eax
    test eax, eax
    jz .Llf_locked
    pause
    jmp .Llf_lock
.Llf_locked:
    mov rax, rsi                      # hash(ino, dev)
    movabs rcx, 0x9E3779B97F4A7C15
    imul rax, rcx
    xor rax, rdi
    mov rcx, rax
    shr rcx, 29
    xor rax, rcx
    and eax, DL_MASK
    xor r9d, r9d
.Llf_probe:
    mov r10d, eax
    shl r10, 4
    add r10, r8
    mov r11, [r10]
    test r11, r11
    jz .Llf_insert
    cmp r11, rsi
    jne .Llf_next
    cmp [r10 + 8], rdi
    jne .Llf_next
    xor eax, eax                      # seen before
    jmp .Llf_unlock
.Llf_next:
    inc eax
    and eax, DL_MASK
    inc r9d
    cmp r9d, DL_PROBES
    jl .Llf_probe
    mov eax, 1                        # crowded: count it
    jmp .Llf_unlock
.Llf_insert:
    mov [r10], rsi
    mov [r10 + 8], rdi
    inc dword ptr [rip + g_dl_used]
    mov eax, 1
.Llf_unlock:
    mov dword ptr [rip + g_dl_lock], 0
.Llf_ret:
    ret

# void du_links_cleanup(void)
du_links_cleanup:
    mov rdi, [rip + g_dl_tbl]
    test rdi, rdi
    jz .Llc_ret
    mov qword ptr [rip + g_dl_tbl], 0
    jmp mem_free
.Llc_ret:
    ret
