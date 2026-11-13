# Core Memory Allocator & Low-Level Memory Routines
# Uses anonymous mmap/mremap/munmap with a 16-byte header storing mapped length.

.intel_syntax noprefix
.include "pal.inc"

.section .text
.global mem_alloc
.global mem_free
.global mem_realloc
.global mem_copy
.global mem_move
.global mem_set
.global mem_zero
.global mem_cmp

# void *mem_alloc(size_t size)
# rdi = size -> returns rax = zeroed 16-byte aligned pointer, or 0 on error
mem_alloc:
    test rdi, rdi
    jnz .Lalloc_non_zero
    mov rdi, 16
.Lalloc_non_zero:
    # total = align_up_page(size + 16)
    lea rsi, [rdi + 16 + 4095]
    and rsi, -4096

    push rsi                  # save mapped_size across syscall
    xor rdi, rdi              # addr = NULL
    # rsi = length (already set)
    mov rdx, PROT_RW
    OS_MMAP_ANON
    pop rsi

    cmp rax, -4095
    jae .Lalloc_fail

    mov [rax], rsi            # store total mapped size at [base + 0]
    add rax, 16               # return 16-byte aligned payload ptr
    ret

.Lalloc_fail:
    xor eax, eax
    ret

# void mem_free(void *ptr)
# rdi = ptr (safe if NULL)
mem_free:
    test rdi, rdi
    jz .Lfree_done
    sub rdi, 16
    mov rsi, [rdi]            # mapped size
    OS_MUNMAP
.Lfree_done:
    ret

# void *mem_realloc(void *ptr, size_t new_size)
# rdi = ptr, rsi = new_size -> returns rax = new ptr, or 0 on failure
mem_realloc:
    test rdi, rdi
    jnz .Lrealloc_existing
    mov rdi, rsi
    jmp mem_alloc

.Lrealloc_existing:
    push rbx
    sub rdi, 16
    mov rbx, [rdi]            # old_mapped_size
    lea rdx, [rsi + 16 + 4095]
    and rdx, -4096            # new_mapped_size

    cmp rdx, rbx
    jbe .Lrealloc_same        # already fits within mapped pages

    sub rsp, 16
    mov [rsp], rdx
    mov rsi, rbx              # old_size
    # rdx = new_size
    call os_mem_remap
    mov rdx, [rsp]
    add rsp, 16

    test rax, rax
    jz .Lrealloc_fail

    mov [rax], rdx
    add rax, 16
    pop rbx
    ret

.Lrealloc_same:
    lea rax, [rdi + 16]
    pop rbx
    ret

.Lrealloc_fail:
    xor eax, eax
    pop rbx
    ret

# void mem_copy(void *dst, const void *src, size_t len)
mem_copy:
    test rdx, rdx
    jz .Lmc_done
    mov rcx, rdx
    rep movsb
.Lmc_done:
    ret

# void mem_move(void *dst, const void *src, size_t len)
mem_move:
    test rdx, rdx
    jz .Lmm_done
    cmp rdi, rsi
    je .Lmm_done
    jb .Lmm_fwd
    lea rax, [rsi + rdx]
    cmp rdi, rax
    jae .Lmm_fwd
    # Backward copy for overlapping dst > src
    lea rdi, [rdi + rdx - 1]
    lea rsi, [rsi + rdx - 1]
    mov rcx, rdx
    std
    rep movsb
    cld
    ret
.Lmm_fwd:
    mov rcx, rdx
    rep movsb
.Lmm_done:
    ret

# void mem_set(void *dst, int byte, size_t len)
mem_set:
    test rdx, rdx
    jz .Lms_done
    mov eax, esi
    mov rcx, rdx
    rep stosb
.Lms_done:
    ret

# void mem_zero(void *dst, size_t len)
mem_zero:
    mov rdx, rsi
    xor esi, esi
    jmp mem_set

# int mem_cmp(const void *a, const void *b, size_t len)
mem_cmp:
    test rdx, rdx
    jz .Lmcmp_eq
    mov rcx, rdx
    repe cmpsb
    je .Lmcmp_eq
    movzx eax, byte ptr [rdi - 1]
    movzx edx, byte ptr [rsi - 1]
    sub eax, edx
    ret
.Lmcmp_eq:
    xor eax, eax
    ret
