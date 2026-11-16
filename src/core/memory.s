# Core Memory Allocator & Low-Level Memory Routines
#
# Hybrid allocator:
#   * Small objects (size + 16 <= 64 KiB): power-of-two slab classes 64 B .. 64 KiB carved
#     from 256 KiB anonymous arenas, recycled through per-class free lists -> O(1), no syscall
#     after warm-up (copy buffers, dirent frames, dialogs, widgets, jobs).
#   * Large objects: dedicated anonymous mmap / mremap / munmap (DirModel arrays, screens).
# Every block carries a 16-byte header; header[0] holds either the mapped byte size of a
# large block (always a multiple of 4096) or the slab tag (class index + 1, never page-aligned).
# All returned memory is zero-filled. Single-threaded by design (background work runs in a
# forked process with its own copy-on-write allocator state).
# Bulk copy/fill/compare delegate to PAL SIMD kernels (src/os/<os>/<arch>/pal_simd.s).

.intel_syntax noprefix
.include "pal.inc"

.equ SLAB_MIN_SHIFT, 6               # 64 B blocks
.equ SLAB_MAX_SHIFT, 16              # 64 KiB blocks
.equ SLAB_CLASSES,   SLAB_MAX_SHIFT - SLAB_MIN_SHIFT + 1
.equ SLAB_ARENA,     262144          # refill granularity (256 KiB)
.equ SLAB_MAX_REQ,   (1 << SLAB_MAX_SHIFT) - 16
.equ MAX_SLAB_ARENAS, 256

.section .bss
.align 8
slab_free:       .space 8 * SLAB_CLASSES   # free-list heads (block header addresses)
slab_bump:       .space 8 * SLAB_CLASSES   # next uncarved block in the current arena
slab_end:        .space 8 * SLAB_CLASSES   # end of the current arena
slab_arena_base: .space 8 * MAX_SLAB_ARENAS
slab_arena_live: .space 4 * MAX_SLAB_ARENAS
slab_cur_arena:  .space 4 * SLAB_CLASSES
slab_arena_cnt:  .space 4

.section .text
.global mem_alloc
.global mem_free
.global mem_realloc
.global mem_copy
.global mem_move
.global mem_set
.global mem_zero
.global mem_cmp
.global mem_slab_arena_count

# void *mem_alloc(size_t size)
# rdi = size -> returns rax = zeroed 16-byte aligned pointer, or 0 on error
mem_alloc:
.ifdef MEMCHECK
    mov r10, [rsp]
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, r10
    call mem_alloc_raw
    test rax, rax; jz 1f
    mov r13, rax
    mov rdi, rax; mov rsi, rbx; mov rdx, r12
    call mc_on_alloc
    mov rax, r13
1:  pop r13; pop r12; pop rbx; ret
mem_alloc_raw:
.endif
    test rdi, rdi; jnz .Lalloc_nz
    mov edi, 1
.Lalloc_nz:
    cmp rdi, SLAB_MAX_REQ; ja mem_alloc_big

    # class k = max(6, bsr(size + 15) + 1); idx = k - 6
    lea rax, [rdi + 15]
    bsr rcx, rax
    inc ecx
    cmp ecx, SLAB_MIN_SHIFT
    jae .Lalloc_cls
    mov ecx, SLAB_MIN_SHIFT
.Lalloc_cls:
    sub ecx, SLAB_MIN_SHIFT           # idx
    lea r8, [rip + slab_free]
    mov rax, [r8 + rcx * 8]
    test rax, rax
    jz .Lalloc_carve
    mov rdx, [rax + 8]                # pop free list
    mov [r8 + rcx * 8], rdx
    mov rdx, [rax]; shr rdx, 12       # arena_idx + 1
    test edx, edx; jz .Lalloc_pop_z
    dec edx
    lea r10, [rip + slab_arena_live]
    inc dword ptr [r10 + rdx * 4]
.Lalloc_pop_z:
    # Recycled block: zero header link + payload (block_size - 8 bytes from +8)
    mov r9, rax
    add ecx, SLAB_MIN_SHIFT
    mov edx, 1
    shl rdx, cl                       # block size
    lea rdi, [r9 + 8]
    sub rdx, 8
    xor esi, esi
    call os_mem_set_fast
    lea rax, [r9 + 16]
    ret

.Lalloc_carve:
    lea r9, [rip + slab_bump]
    lea r10, [rip + slab_end]
.Lalloc_try:
    mov rax, [r9 + rcx * 8]
    test rax, rax
    jz .Lalloc_refill
    mov r11, rcx
    add ecx, SLAB_MIN_SHIFT
    mov edx, 1
    shl rdx, cl                       # block size
    mov rcx, r11
    add rdx, rax
    cmp rdx, [r10 + rcx * 8]
    ja .Lalloc_refill
    mov [r9 + rcx * 8], rdx
    lea r10, [rip + slab_cur_arena]
    mov r8d, [r10 + rcx * 4]          # arena_idx + 1
    test r8d, r8d; jz .Lalloc_tag
    lea r11d, [r8d - 1]
    lea r10, [rip + slab_arena_live]
    inc dword ptr [r10 + r11 * 4]
.Lalloc_tag:
    shl r8, 12
    lea edx, [ecx + 1]
    or rdx, r8
    mov [rax], rdx                    # slab tag (fresh arena memory is already zero)
    add rax, 16
    ret

.Lalloc_refill:
    call mem_arena_refill
    test rax, rax
    jz .Lalloc_fail
    lea r9, [rip + slab_bump]
    lea r10, [rip + slab_end]
    jmp .Lalloc_try

# void *mem_arena_refill(int cls_idx in rcx) -> base or 0, preserves rcx
mem_arena_refill:
    push rcx
    xor edi, edi
    mov esi, SLAB_ARENA
    mov edx, PROT_RW
    OS_MMAP_ANON
    pop rcx
    cmp rax, -4095
    jae .Lmar_fail
    lea r9, [rip + slab_bump]
    lea r10, [rip + slab_end]
    mov [r9 + rcx * 8], rax
    lea rdx, [rax + SLAB_ARENA]
    mov [r10 + rcx * 8], rdx
    lea r8, [rip + slab_arena_base]
    xor edx, edx
.Lmar_slot:
    cmp edx, MAX_SLAB_ARENAS; jae .Lmar_full
    cmp qword ptr [r8 + rdx * 8], 0; je .Lmar_reg
    inc edx; jmp .Lmar_slot
.Lmar_reg:
    mov [r8 + rdx * 8], rax
    lea r8, [rip + slab_arena_live]
    mov dword ptr [r8 + rdx * 4], 0
    inc edx
    lea r8, [rip + slab_cur_arena]
    mov [r8 + rcx * 4], edx
    inc dword ptr [rip + slab_arena_cnt]
    ret
.Lmar_full:
    lea r8, [rip + slab_cur_arena]
    mov dword ptr [r8 + rcx * 4], 0
    ret
.Lmar_fail:
    xor eax, eax
    ret

.Lalloc_fail:
    xor eax, eax
    ret

mem_alloc_big:
    mov rax, -4112
    cmp rdi, rax
    ja .Lalloc_fail
    # total = align_up_page(size + 16)
    lea rsi, [rdi + 16 + 4095]
    and rsi, -4096
    push rsi
    xor edi, edi
    mov rdx, PROT_RW
    OS_MMAP_ANON
    pop rsi
    cmp rax, -4095
    jae .Lalloc_fail
    mov [rax], rsi                    # mapped size
    add rax, 16
    ret

# void mem_free(void *ptr) -- safe on NULL
mem_free:
.ifdef MEMCHECK
    test rdi, rdi
    jz .Lfree_done
    mov rsi, [rsp]
    push rdi; sub rsp, 8
    call mc_on_free
    add rsp, 8; pop rdi
mem_free_raw:
.endif
    test rdi, rdi
    jz .Lfree_done
    sub rdi, 16
    mov rax, [rdi]
    test eax, 4095
    jnz .Lfree_slab
    mov rsi, rax
    OS_MUNMAP
.Lfree_done:
    ret
.Lfree_slab:
    mov r8, rax
    shr r8, 12                        # arena_idx + 1
    and eax, 0xF
    dec eax                           # idx
    lea rcx, [rip + slab_free]
    mov rdx, [rcx + rax * 8]
    mov [rdi + 8], rdx
    mov [rcx + rax * 8], rdi
    test r8d, r8d
    jz .Lfree_done
    dec r8d
    lea r9, [rip + slab_arena_live]
    dec dword ptr [r9 + r8 * 4]
    jnz .Lfree_done
    cmp dword ptr [rip + slab_arena_cnt], 1
    jle .Lfree_done
    mov edi, r8d
    mov esi, eax
    jmp mem_reclaim_arena

# void mem_reclaim_arena(int arena_idx, int cls_idx)
mem_reclaim_arena:
    lea r8, [rip + slab_arena_base]
    mov r9, [r8 + rdi * 8]            # base
    test r9, r9; jz .Lmra_ret
    lea r10, [r9 + SLAB_ARENA]        # end
    lea rcx, [rip + slab_free]
    lea rcx, [rcx + rsi * 8]          # prev_ptr = &slab_free[cls]
.Lmra_unlink:
    mov rdx, [rcx]
    test rdx, rdx; jz .Lmra_cur
    cmp rdx, r9; jb .Lmra_keep
    cmp rdx, r10; jae .Lmra_keep
    mov r11, [rdx + 8]
    mov [rcx], r11
    jmp .Lmra_unlink
.Lmra_keep:
    lea rcx, [rdx + 8]
    jmp .Lmra_unlink
.Lmra_cur:
    lea eax, [edi + 1]
    lea rcx, [rip + slab_cur_arena]
    cmp [rcx + rsi * 4], eax; jne .Lmra_unmap
    mov dword ptr [rcx + rsi * 4], 0
    lea rcx, [rip + slab_bump]; mov qword ptr [rcx + rsi * 8], 0
    lea rcx, [rip + slab_end];  mov qword ptr [rcx + rsi * 8], 0
.Lmra_unmap:
    mov qword ptr [r8 + rdi * 8], 0
    dec dword ptr [rip + slab_arena_cnt]
    mov rdi, r9
    mov esi, SLAB_ARENA
    OS_MUNMAP
.Lmra_ret:
    ret

# int mem_slab_arena_count(void)
mem_slab_arena_count:
    mov eax, [rip + slab_arena_cnt]
    ret

# void *mem_realloc(void *ptr, size_t new_size)
# rdi = ptr, rsi = new_size -> returns rax = new ptr, or 0 on failure (old block intact)
mem_realloc:
.ifdef MEMCHECK
    mov r10, [rsp]
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13, r10
    call mem_realloc_raw
    test rax, rax; jz 1f
    push rax; sub rsp, 8
    mov rdi, rbx; mov rsi, rax; mov rdx, r12; mov rcx, r13
    call mc_on_realloc
    add rsp, 8; pop rax
1:  pop r13; pop r12; pop rbx; ret
mem_realloc_raw:
.endif
    test rdi, rdi
    jnz .Lrealloc_existing
    mov rdi, rsi
.ifdef MEMCHECK
    jmp mem_alloc_raw
.else
    jmp mem_alloc
.endif

.Lrealloc_existing:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx - 16]
    test eax, 4095
    jnz .Lrealloc_slab

    lea rdx, [r12 + 16 + 4095]
    and rdx, -4096                    # new_mapped_size
    cmp rdx, rax
    jbe .Lrealloc_same
    mov r13, rdx
    lea rdi, [rbx - 16]
    mov rsi, rax
    call os_mem_remap
    test rax, rax
    jz .Lrealloc_fail
    mov [rax], r13
    add rax, 16
    jmp .Lrealloc_ret

.Lrealloc_slab:
    and eax, 0xF
    lea ecx, [eax - 1 + SLAB_MIN_SHIFT]
    mov r13d, 1
    shl r13, cl                       # block size
    lea rax, [r12 + 16]
    cmp rax, r13
    jbe .Lrealloc_same
    mov rdi, r12
.ifdef MEMCHECK
    call mem_alloc_raw
.else
    call mem_alloc
.endif
    test rax, rax
    jz .Lrealloc_fail
    mov r12, rax
    mov rdi, rax
    mov rsi, rbx
    lea rdx, [r13 - 16]
    call os_mem_copy_fast
    mov rdi, rbx
.ifdef MEMCHECK
    call mem_free_raw
.else
    call mem_free
.endif
    mov rax, r12
    jmp .Lrealloc_ret

.Lrealloc_same:
    mov rax, rbx
    jmp .Lrealloc_ret
.Lrealloc_fail:
    xor eax, eax
.Lrealloc_ret:
    pop r13
    pop r12
    pop rbx
    ret

# void mem_copy(void *dst, const void *src, size_t len)  (clobbers rcx, rdi, rsi)
mem_copy:
    jmp os_mem_copy_fast

# void mem_move(void *dst, const void *src, size_t len)  (overlap-safe)
mem_move:
    jmp os_mem_move_fast

# void mem_set(void *dst, int byte, size_t len)
mem_set:
    jmp os_mem_set_fast

# void mem_zero(void *dst, size_t len)
mem_zero:
    mov rdx, rsi
    xor esi, esi
    jmp os_mem_set_fast

# int mem_cmp(const void *a, const void *b, size_t len)
mem_cmp:
    jmp os_mem_cmp_fast
