# src/fs/du_cache.s - In-memory recursive directory size cache for instant Disk Usage navigation
.intel_syntax noprefix

.include "pal.inc"
.equ DU_CACHE_CAP,  131072
.equ DU_CACHE_MASK, 0x1FFFF
.equ DU_SLOT_SZ,    32        # ino(8), dev(8), mtime_sig(8), size(8)

.section .bss
.align 8
g_du_tbl:   .space 8          # DuSlot* (heap, DU_CACHE_CAP * 32 = 4 MiB)
g_du_lock:  .space 4          # spinlock for multi-threaded du_cache access

.section .text
.global du_cache_init
.global du_cache_get
.global du_cache_put
.global du_cache_cleanup

.extern mem_alloc
.extern mem_free
.extern mem_zero

# uint64_t du_hash_key(uint64_t ino, uint64_t dev)
du_hash_key:
    mov rax, rdi
    movabs rcx, 0x9E3779B97F4A7C15
    imul rax, rcx
    xor rax, rsi
    mov rcx, rax
    shr rcx, 30
    xor rax, rcx
    movabs rcx, 0xBF58476D1CE4E5B9
    imul rax, rcx
    and eax, DU_CACHE_MASK
    ret

du_spin_lock:
    mov eax, 1
    xchg [rip + g_du_lock], eax
    test eax, eax
    jnz .Lds_wait
    ret
.Lds_wait:
    pause
    cmp dword ptr [rip + g_du_lock], 0
    jne .Lds_wait
    jmp du_spin_lock

du_spin_unlock:
    mov dword ptr [rip + g_du_lock], 0
    ret

# void *du_cache_init(void) - safe to call repeatedly from main thread
du_cache_init:
    mov rax, [rip + g_du_tbl]
    test rax, rax
    jnz .Ldci_ret
    push rbx
    mov edi, DU_CACHE_CAP * DU_SLOT_SZ
    call mem_alloc
    test rax, rax
    jz .Ldci_pop
    mov rbx, rax
    mov rdi, rbx
    mov esi, DU_CACHE_CAP * DU_SLOT_SZ
    call mem_zero
    mov [rip + g_du_tbl], rbx
    mov rax, rbx
.Ldci_pop:
    pop rbx
.Ldci_ret:
    ret

# int du_cache_get(uint64_t ino, uint64_t dev, int64_t mtime_sig, uint64_t *out_size) -> 1 hit, 0 miss
du_cache_get:
    mov rax, [rip + g_du_tbl]
    test rax, rax
    jz .Ldcg_miss
    test rdi, rdi
    jz .Ldcg_miss
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # ino
    mov r12, rsi              # dev
    mov r13, rdx              # mtime_sig
    mov r14, rcx              # out_size
    call du_spin_lock
    mov rdi, rbx
    mov rsi, r12
    call du_hash_key
    mov r8, [rip + g_du_tbl]
    xor r9d, r9d              # probe count (max 16)
.Ldcg_probe:
    mov r10d, eax
    shl r10, 5                # * 32
    add r10, r8
    mov r11, [r10]            # slot.ino
    test r11, r11
    jz .Ldcg_no
    cmp r11, rbx
    jne .Ldcg_next
    cmp [r10 + 8], r12
    jne .Ldcg_next
    cmp [r10 + 16], r13
    jne .Ldcg_no              # stale mtime -> treat as miss
    mov rdx, [r10 + 24]
    mov [r14], rdx
    mov ebx, 1
    jmp .Ldcg_unlock
.Ldcg_next:
    inc eax
    and eax, DU_CACHE_MASK
    inc r9d
    cmp r9d, 16
    jl .Ldcg_probe
.Ldcg_no:
    xor ebx, ebx
.Ldcg_unlock:
    call du_spin_unlock
    mov eax, ebx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Ldcg_miss:
    xor eax, eax
    ret

# void du_cache_put(uint64_t ino, uint64_t dev, int64_t mtime_sig, uint64_t size)
du_cache_put:
    test rdi, rdi
    jz .Ldcp_ret
    cmp qword ptr [rip + g_du_tbl], 0
    jz .Ldcp_ret
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call du_spin_lock
    mov r8, [rip + g_du_tbl]
    mov rdi, rbx
    mov rsi, r12
    call du_hash_key
    mov r8, [rip + g_du_tbl]
    xor r9d, r9d
.Ldcp_probe:
    mov r10d, eax
    shl r10, 5
    add r10, r8
    mov r11, [r10]
    test r11, r11
    jz .Ldcp_store
    cmp r11, rbx
    jne .Ldcp_next
    cmp [r10 + 8], r12
    je .Ldcp_store
.Ldcp_next:
    inc eax
    and eax, DU_CACHE_MASK
    inc r9d
    cmp r9d, 16
    jl .Ldcp_probe
    # Evict initial slot on full probe chain
    mov rdi, rbx
    mov rsi, r12
    call du_hash_key
    mov r8, [rip + g_du_tbl]
    mov r10d, eax
    shl r10, 5
    add r10, r8
.Ldcp_store:
    mov [r10], rbx
    mov [r10 + 8], r12
    mov [r10 + 16], r13
    mov [r10 + 24], r14
    call du_spin_unlock
.Ldcp_out:
    pop r14
    pop r13
    pop r12
    pop rbx
.Ldcp_ret:
    ret

# void du_cache_cleanup(void)
du_cache_cleanup:
    mov rdi, [rip + g_du_tbl]
    test rdi, rdi
    jz .Ldcc_ret
    mov qword ptr [rip + g_du_tbl], 0
    jmp mem_free
.Ldcc_ret:
    ret
