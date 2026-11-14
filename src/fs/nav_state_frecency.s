# Duop Navigation State: Per-tab History, Bookmarks (Hotlist) & Frecency (z) — frecency (split from nav_state.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.equ TAB_MAX,           8
.equ HIST_MAX,          32
.equ BM_MAX,            64
.equ FRE_MAX,           128
.equ TAB_PATH,          0
.equ TAB_CURSOR,        4096
.equ TAB_SCROLL,        4100
.equ TAB_SORT_MODE,     4104
.equ TAB_SORT_DESC,     4108
.equ TAB_SHOW_HIDDEN,   4112
.equ TAB_HIST_POS,      4116
.equ TAB_HIST_LEN,      4120
.equ TAB_HIST_PAD,      4124
.equ TAB_HIST_PTRS,     4128
.equ TAB_SIZE,          4384

.section .bss
g_fre_cnt:      .space 4
g_fre_scores:   .space FRE_MAX * 4
g_fre_ptrs:     .space FRE_MAX * 8

.section .rodata
str_fre_file:   .asciz "frecency"

.section .text
.global nav_frecency_load
.global nav_frecency_record
.global nav_frecency_count
.global nav_frecency_get
.global nav_frecency_score
.global nav_frecency_match
.global g_fre_cnt

# Internal: load frecency file ("<score> <path>\n")
nav_frecency_load:
    cmp dword ptr [rip + g_data_ready], 0
    je .Lnfl_ret
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16384
    call nav_frecency_load__path_join
    call nav_frecency_load__part2
    js .Lnfl_done
    call nav_frecency_load__sys_read_retry
    call nav_frecency_load__parse_score_digits
.Lnfl_done:
    add rsp, PATH_MAX + 16384
    pop r13
    pop r12
    pop rbx
.Lnfl_ret:
    ret

# nav_frecency_load step: path_join (runs on the caller's frame)
nav_frecency_load__path_join:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    lea rsi, [rip + g_data_dir]
    lea rdx, [rip + str_fre_file]
    mov ecx, PATH_MAX
    call path_join

.Lnav_frecency_load__path_join_ret:
    lea rsp, [rsp + 8]
    ret

# nav_frecency_load step (runs on the caller's frame)
nav_frecency_load__part2:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    lea rsi, [rsp + 16]
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lnav_frecency_load__part2_ret:
    lea rsp, [rsp + 8]
    ret

# nav_frecency_load step: sys_read_retry (runs on the caller's frame)
nav_frecency_load__sys_read_retry:
    lea rsp, [rsp - 8]
    mov ebx, eax
    lea r12, [rsp + PATH_MAX + 16]
    mov edi, ebx
    mov rsi, r12
    mov edx, 16383
    call sys_read_retry
    mov r13, rax
    mov edi, ebx
    OS_CLOSE
    test r13, r13
.Lnav_frecency_load__sys_read_retry_ret:
    lea rsp, [rsp + 8]
    ret

# nav_frecency_load step: Parse score digits (runs on the caller's frame)
nav_frecency_load__parse_score_digits:
    lea rsp, [rsp - 8]
    jle .Lnav_frecency_load__parse_score_digits_ret
    mov byte ptr [r12 + r13], 0

    mov rbx, r12
.Lnfl_line:
    cmp byte ptr [rbx], 0
    je .Lnav_frecency_load__parse_score_digits_ret
    cmp dword ptr [rip + g_fre_cnt], FRE_MAX
    jge .Lnav_frecency_load__parse_score_digits_ret
    mov r13, rbx
.Lnfl_eol:
    mov al, [rbx]
    test al, al
    jz .Lnfl_parse
    cmp al, '\n'
    je .Lnfl_term
    inc rbx
    jmp .Lnfl_eol
.Lnfl_term:
    mov byte ptr [rbx], 0
    inc rbx
.Lnfl_parse:
    # Parse score digits
    xor eax, eax
.Lnfl_dig:
    movzx ecx, byte ptr [r13]
    cmp cl, '0'
    jb .Lnfl_sp
    cmp cl, '9'
    ja .Lnfl_sp
    imul eax, eax, 10
    sub cl, '0'
    add eax, ecx
    inc r13
    jmp .Lnfl_dig
.Lnfl_sp:
    cmp byte ptr [r13], ' '
    jne .Lnfl_line
    inc r13
    cmp byte ptr [r13], 0
    je .Lnfl_line
    test eax, eax
    jnz .Lnfl_sc_ok
    mov eax, 1
.Lnfl_sc_ok:
    push rax
    mov rdi, r13
    call nav_strdup
    pop rdx
    test rax, rax
    jz .Lnfl_line
    mov ecx, [rip + g_fre_cnt]
    lea r8, [rip + g_fre_scores]
    mov [r8 + rcx*4], edx
    lea r8, [rip + g_fre_ptrs]
    mov [r8 + rcx*8], rax
    inc ecx
    mov [rip + g_fre_cnt], ecx
    jmp .Lnfl_line

.Lnav_frecency_load__parse_score_digits_ret:
    lea rsp, [rsp + 8]
    ret

# Internal: save frecency file
nav_frecency_save:
    cmp dword ptr [rip + g_data_ready], 0
    je .Lnfs_ret
    push rbx
    push r12
    sub rsp, PATH_MAX + 32
    mov rdi, rsp
    lea rsi, [rip + g_data_dir]
    lea rdx, [rip + str_fre_file]
    mov ecx, PATH_MAX
    call path_join

    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0644
    OS_OPENAT
    test rax, rax
    js .Lnfs_done
    mov ebx, eax
    xor r12d, r12d
.Lnfs_loop:
    cmp r12d, [rip + g_fre_cnt]
    jge .Lnfs_close
    lea rcx, [rip + g_fre_scores]
    mov edi, [rcx + r12*4]
    lea rsi, [rsp + PATH_MAX]
    call nav_u32_to_str
    lea rsi, [rsp + PATH_MAX]
    mov byte ptr [rsi + rax], ' '
    inc eax
    mov edi, ebx
    mov edx, eax
    call sys_write_all

    lea rcx, [rip + g_fre_ptrs]
    mov rdi, [rcx + r12*8]
    push rdi
    call str_len
    pop rsi
    mov rdx, rax
    mov edi, ebx
    call sys_write_all

    mov byte ptr [rsp + PATH_MAX], '\n'
    mov edi, ebx
    lea rsi, [rsp + PATH_MAX]
    mov edx, 1
    call sys_write_all
    inc r12d
    jmp .Lnfs_loop
.Lnfs_close:
    mov edi, ebx
    OS_CLOSE
.Lnfs_done:
    add rsp, PATH_MAX + 32
    pop r12
    pop rbx
.Lnfs_ret:
    ret

# void nav_frecency_record(const char *path)
nav_frecency_record:
    test rdi, rdi
    jz .Lnfr_ret
    cmp byte ptr [rdi], 0
    je .Lnfr_ret
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
.Lnfr_find:
    cmp r12d, [rip + g_fre_cnt]
    jge .Lnfr_new
    lea rcx, [rip + g_fre_ptrs]
    mov rdi, [rcx + r12*8]
    mov rsi, rbx
    call str_cmp
    test eax, eax
    jz .Lnfr_bump
    inc r12d
    jmp .Lnfr_find

.Lnfr_bump:
    lea rcx, [rip + g_fre_scores]
    inc dword ptr [rcx + r12*4]
    jmp .Lnfr_bubble

.Lnfr_new:
    call nav_frecency_record__replace_lowest_entry_fre
    mov rdi, rbx
    call nav_strdup
    test rax, rax
    jz .Lnfr_save
    lea rcx, [rip + g_fre_ptrs]
    mov [rcx + r12*8], rax
    lea rcx, [rip + g_fre_scores]
    mov dword ptr [rcx + r12*4], 1

.Lnfr_bubble:
    # Bubble entry r12d up while score > prev score
    call nav_frecency_record__bubble_entry_r12d_up
.Lnfr_save:
    call nav_frecency_save
    pop r12
    pop rbx
.Lnfr_ret:
    ret

# nav_frecency_record step: Replace lowest entry at FRE_MAX (runs on the caller's frame)
nav_frecency_record__replace_lowest_entry_fre:
    lea rsp, [rsp - 8]
    mov r12d, [rip + g_fre_cnt]
    cmp r12d, FRE_MAX
    jl .Lnfr_alloc
    # Replace lowest entry at FRE_MAX - 1
    dec r12d
    lea rcx, [rip + g_fre_ptrs]
    mov rdi, [rcx + r12*8]
    test rdi, rdi
    jz .Lnfr_alloc
    call mem_free
    jmp .Lnfr_alloc_idx
.Lnfr_alloc:
    inc dword ptr [rip + g_fre_cnt]
.Lnfr_alloc_idx:
.Lnav_frecency_record__replace_lowest_entry_fre_ret:
    lea rsp, [rsp + 8]
    ret

# nav_frecency_record step: Bubble entry r12d up while score prev score (runs on the caller's frame)
nav_frecency_record__bubble_entry_r12d_up:
    lea rsp, [rsp - 8]
    lea r8, [rip + g_fre_scores]
    lea r9, [rip + g_fre_ptrs]
.Lnfr_bub_loop:
    test r12d, r12d
    jle .Lnav_frecency_record__bubble_entry_r12d_up_ret
    lea ecx, [r12d - 1]
    mov eax, [r8 + r12*4]
    mov edx, [r8 + rcx*4]
    cmp eax, edx
    jle .Lnav_frecency_record__bubble_entry_r12d_up_ret
    mov [r8 + r12*4], edx
    mov [r8 + rcx*4], eax
    mov rax, [r9 + r12*8]
    mov rdx, [r9 + rcx*8]
    mov [r9 + r12*8], rdx
    mov [r9 + rcx*8], rax
    mov r12d, ecx
    jmp .Lnfr_bub_loop

.Lnav_frecency_record__bubble_entry_r12d_up_ret:
    lea rsp, [rsp + 8]
    ret

# int nav_frecency_count(void)
nav_frecency_count:
    mov eax, [rip + g_fre_cnt]
    ret

# const char *nav_frecency_get(int idx)
nav_frecency_get:
    cmp edi, 0
    jl .Lnfg_none
    cmp edi, [rip + g_fre_cnt]
    jge .Lnfg_none
    lea rcx, [rip + g_fre_ptrs]
    mov rax, [rcx + rdi*8]
    ret
.Lnfg_none:
    xor eax, eax
    ret

# int nav_frecency_score(int idx)
nav_frecency_score:
    cmp edi, 0
    jl .Lnfs_zero
    cmp edi, [rip + g_fre_cnt]
    jge .Lnfs_zero
    lea rcx, [rip + g_fre_scores]
    mov eax, [rcx + rdi*4]
    ret
.Lnfs_zero:
    xor eax, eax
    ret

# int nav_frecency_match(const char *substr, int *out_indices, int max_out)
nav_frecency_match:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi              # substr
    mov r12, rsi              # out_indices
    mov r13d, edx             # max_out
    xor r14d, r14d            # out_cnt
    xor r15d, r15d            # i
.Lnfm_loop:
    cmp r15d, [rip + g_fre_cnt]
    jge .Lnfm_done
    cmp r14d, r13d
    jge .Lnfm_done
    lea rcx, [rip + g_fre_ptrs]
    mov rdi, [rcx + r15*8]
    mov rsi, rbx
    call nav_ci_contains
    test eax, eax
    jz .Lnfm_next
    mov [r12 + r14*4], r15d
    inc r14d
.Lnfm_next:
    inc r15d
    jmp .Lnfm_loop
.Lnfm_done:
    mov eax, r14d
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
