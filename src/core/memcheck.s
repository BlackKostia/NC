# Compile-time MEMCHECK=1 heap leak & bad-free tracker (zero overhead in release).
.intel_syntax noprefix
.include "pal.inc"

.ifdef MEMCHECK

.equ MC_CAP,      65536
.equ MC_MASK,     65535
.equ MC_ENTRY_SZ, 32                  # [0]=ptr [8]=size [16]=caller [24]=seq
.equ MC_TABLE_BYTES, MC_CAP * MC_ENTRY_SZ
.equ MC_TOMB,     -1

.section .rodata
str_env_mclog: .asciz "DUOP_MEMCHECK_LOG="
.equ ENV_MCLOG_LEN, 18
hex_digits:    .ascii "0123456789abcdef"
str_mc_sum1:   .ascii "MC_SUMMARY allocs="
str_mc_sum2:   .ascii " frees="
str_mc_sum3:   .ascii " live="
str_mc_sum4:   .ascii " live_bytes="
str_mc_sum5:   .ascii " peak_bytes="
str_mc_sum6:   .ascii " bad_frees="
str_mc_leak1:  .ascii "MC_LEAK ptr="
str_mc_leak2:  .ascii " size="
str_mc_leak3:  .ascii " caller="
str_mc_leak4:  .ascii " seq="
str_mc_bad1:   .ascii "MC_BADFREE ptr="
str_mc_bad2:   .ascii " caller="

.section .bss
.align 8
mc_table:        .space 8
mc_total_allocs: .space 8
mc_total_frees:  .space 8
mc_live_cnt:     .space 8
mc_live_bytes:   .space 8
mc_peak_bytes:   .space 8
mc_bad_frees:    .space 8
mc_seq:          .space 8
mc_log_fd:       .space 4
mc_pad:          .space 4

.section .text
.global mc_init
.global mc_on_alloc
.global mc_on_free
.global mc_on_realloc
.global mc_report

# void mc_init(char **envp)
mc_init:
    push rbx; push r12
    mov dword ptr [rip + mc_log_fd], STDERR_FD
    mov rbx, rdi
    test rbx, rbx; jz .Lmi_mmap
.Lmi_env:
    mov r12, [rbx]; test r12, r12; jz .Lmi_mmap
    lea rdi, [rip + str_env_mclog]
    mov rsi, r12; mov edx, ENV_MCLOG_LEN
    call mem_cmp; test eax, eax; jz .Lmi_open
    add rbx, 8; jmp .Lmi_env
.Lmi_open:
    lea rsi, [r12 + ENV_MCLOG_LEN]
    mov edi, AT_FDCWD
    mov edx, O_WRONLY | O_CREAT | O_TRUNC
    mov r10d, 0644
    OS_OPENAT
    test rax, rax; js .Lmi_mmap
    mov [rip + mc_log_fd], eax
.Lmi_mmap:
    xor edi, edi; mov esi, MC_TABLE_BYTES; mov edx, PROT_RW
    OS_MMAP_ANON
    cmp rax, -4095; jae .Lmi_done
    mov [rip + mc_table], rax
.Lmi_done:
    pop r12; pop rbx; ret

# Internal: size_t mc_hash(uint64_t ptr) -> slot
mc_hash:
    mov rax, rdi; shr rax, 4
    mov rcx, 0x9E3779B97F4A7C15
    imul rax, rcx; xor rax, rdi
    and eax, MC_MASK; ret

# void mc_on_alloc(void *ptr, size_t size, uint64_t caller)
mc_on_alloc:
    test rdi, rdi; jz .Lma_ret
    mov r8, [rip + mc_table]; test r8, r8; jz .Lma_ret
    push rbx; push r12; push r13; push r14
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov r14, r8
    call mc_hash
    mov ecx, eax; xor r9d, r9d
.Lma_probe:
    mov rdx, rcx; shl rdx, 5; add rdx, r14
    mov r10, [rdx]
    test r10, r10; jz .Lma_ins
    cmp r10, MC_TOMB; je .Lma_ins
    inc ecx; and ecx, MC_MASK
    inc r9d; cmp r9d, MC_CAP; jb .Lma_probe
    pop r14; pop r13; pop r12; pop rbx
.Lma_ret:
    ret
.Lma_ins:
    mov [rdx], rbx; mov [rdx + 8], r12; mov [rdx + 16], r13
    inc qword ptr [rip + mc_seq]
    mov rax, [rip + mc_seq]; mov [rdx + 24], rax
    inc qword ptr [rip + mc_total_allocs]
    inc qword ptr [rip + mc_live_cnt]
    add [rip + mc_live_bytes], r12
    mov rax, [rip + mc_live_bytes]
    cmp rax, [rip + mc_peak_bytes]; jbe 1f
    mov [rip + mc_peak_bytes], rax
1:  pop r14; pop r13; pop r12; pop rbx; ret

# void mc_on_free(void *ptr, uint64_t caller)
mc_on_free:
    test rdi, rdi; jz .Lmf_ret
    mov r8, [rip + mc_table]; test r8, r8; jz .Lmf_ret
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13, r8
    call mc_hash
    mov ecx, eax; xor r9d, r9d
.Lmf_probe:
    mov rdx, rcx; shl rdx, 5; add rdx, r13
    mov r10, [rdx]
    test r10, r10; jz .Lmf_bad
    cmp r10, rbx; je .Lmf_hit
    inc ecx; and ecx, MC_MASK
    inc r9d; cmp r9d, MC_CAP; jb .Lmf_probe
.Lmf_bad:
    inc qword ptr [rip + mc_bad_frees]
    mov rdi, rbx; mov rsi, r12; call mc_log_badfree
    pop r13; pop r12; pop rbx
.Lmf_ret:
    ret
.Lmf_hit:
    mov qword ptr [rdx], MC_TOMB
    mov rax, [rdx + 8]; sub [rip + mc_live_bytes], rax
    dec qword ptr [rip + mc_live_cnt]
    inc qword ptr [rip + mc_total_frees]
    pop r13; pop r12; pop rbx; ret

# void mc_on_realloc(void *old_ptr, void *new_ptr, size_t new_size, uint64_t caller)
mc_on_realloc:
    push rbx; push r12; push r13
    mov rbx, rsi; mov r12, rdx; mov r13, rcx
    test rdi, rdi; jz 1f
    mov rsi, r13; call mc_on_free
1:  test rbx, rbx; jz 2f
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; call mc_on_alloc
2:  pop r13; pop r12; pop rbx; ret

# Internal: char *mc_put_str(char *p, const char *s, size_t len)
mc_put_str:
    push rdi; push rdx
    mov rcx, rdx; mov rdx, rdi; mov rdi, rdx; rep movsb
    mov rax, rdi; add rsp, 16; ret

# Internal: char *mc_put_hex(char *p, uint64_t val)
mc_put_hex:
    mov word ptr [rdi], 0x7830        # "0x"
    add rdi, 2
    lea r8, [rip + hex_digits]
    mov ecx, 60
1:  mov rax, rsi; shr rax, cl; and eax, 15
    mov al, [r8 + rax]; mov [rdi], al; inc rdi
    sub ecx, 4; jns 1b
    mov rax, rdi; ret

# Internal: char *mc_put_dec(char *p, uint64_t val)
mc_put_dec:
    push rdi; mov rdi, rsi; pop rsi
    push rsi; call u64_to_dec; pop rsi
    add rax, rsi; ret

# Internal: void mc_flush_line(char *start, char *end)
mc_flush_line:
    mov byte ptr [rsi], '\n'; inc rsi
    sub rsi, rdi; mov rdx, rsi; mov rsi, rdi
    mov edi, [rip + mc_log_fd]
    OS_WRITE; ret

# Internal: void mc_log_badfree(void *ptr, uint64_t caller)
mc_log_badfree:
    push rbx; push r12; push r13; sub rsp, 128
    mov r12, rdi; mov r13, rsi; mov rbx, rsp
    mov rdi, rbx; lea rsi, [rip + str_mc_bad1]; mov edx, 15; call mc_put_str
    mov rdi, rax; mov rsi, r12; call mc_put_hex
    mov rdi, rax; lea rsi, [rip + str_mc_bad2]; mov edx, 8; call mc_put_str
    mov rdi, rax; mov rsi, r13; call mc_put_hex
    mov rdi, rbx; mov rsi, rax; call mc_flush_line
    add rsp, 128; pop r13; pop r12; pop rbx; ret

# void mc_report(void)
mc_report:
    push rbx; push r12; push r13; sub rsp, 256
    mov rbx, rsp
    mov rdi, rbx; lea rsi, [rip + str_mc_sum1]; mov edx, 18; call mc_put_str
    mov rdi, rax; mov rsi, [rip + mc_total_allocs]; call mc_put_dec
    mov rdi, rax; lea rsi, [rip + str_mc_sum2]; mov edx, 7; call mc_put_str
    mov rdi, rax; mov rsi, [rip + mc_total_frees]; call mc_put_dec
    mov rdi, rax; lea rsi, [rip + str_mc_sum3]; mov edx, 6; call mc_put_str
    mov rdi, rax; mov rsi, [rip + mc_live_cnt]; call mc_put_dec
    mov rdi, rax; lea rsi, [rip + str_mc_sum4]; mov edx, 12; call mc_put_str
    mov rdi, rax; mov rsi, [rip + mc_live_bytes]; call mc_put_dec
    mov rdi, rax; lea rsi, [rip + str_mc_sum5]; mov edx, 12; call mc_put_str
    mov rdi, rax; mov rsi, [rip + mc_peak_bytes]; call mc_put_dec
    mov rdi, rax; lea rsi, [rip + str_mc_sum6]; mov edx, 11; call mc_put_str
    mov rdi, rax; mov rsi, [rip + mc_bad_frees]; call mc_put_dec
    mov rdi, rbx; mov rsi, rax; call mc_flush_line
    mov r12, [rip + mc_table]; test r12, r12; jz .Lmr_close
    xor r13d, r13d
.Lmr_lp:
    cmp r13d, MC_CAP; jae .Lmr_close
    mov rax, r13; shl rax, 5; add rax, r12
    mov rcx, [rax]; test rcx, rcx; jz .Lmr_nxt
    cmp rcx, MC_TOMB; je .Lmr_nxt
    push rax
    mov rdi, rbx; lea rsi, [rip + str_mc_leak1]; mov edx, 12; call mc_put_str
    mov rcx, [rsp]; mov rsi, [rcx]; mov rdi, rax; call mc_put_hex
    mov rdi, rax; lea rsi, [rip + str_mc_leak2]; mov edx, 6; call mc_put_str
    mov rcx, [rsp]; mov rsi, [rcx + 8]; mov rdi, rax; call mc_put_dec
    mov rdi, rax; lea rsi, [rip + str_mc_leak3]; mov edx, 8; call mc_put_str
    mov rcx, [rsp]; mov rsi, [rcx + 16]; mov rdi, rax; call mc_put_hex
    mov rdi, rax; lea rsi, [rip + str_mc_leak4]; mov edx, 5; call mc_put_str
    mov rcx, [rsp]; mov rsi, [rcx + 24]; mov rdi, rax; call mc_put_dec
    pop rcx
    mov rdi, rbx; mov rsi, rax; call mc_flush_line
.Lmr_nxt:
    inc r13d; jmp .Lmr_lp
.Lmr_close:
    mov edi, [rip + mc_log_fd]
    cmp edi, 2; jle 1f
    OS_CLOSE
1:  add rsp, 256; pop r13; pop r12; pop rbx; ret

.endif
