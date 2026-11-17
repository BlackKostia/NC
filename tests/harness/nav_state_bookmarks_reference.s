# Frozen reference oracle: the hand-written asm that src/fs/nav_state.c and nav_persist.c replaced (tests/test_c_nav_state.py diffs against it)
# Duop Navigation State: Per-tab History, Bookmarks (Hotlist) & Frecency (z) — bookmarks (split from nav_state.s)

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

.align 8
g_data_dir:     .space PATH_MAX
g_data_ready:   .space 4
g_bm_cnt:       .space 4
g_bm_ptrs:      .space BM_MAX * 8

.section .rodata
str_bm_file:    .asciz "bookmarks"

.section .text
.global nav_bookmarks_load
.global nav_bookmarks_count
.global nav_bookmarks_get
.global nav_bookmarks_add
.global nav_bookmarks_remove
.global g_data_dir
.global g_data_ready
.global g_bm_cnt
.global g_bm_ptrs

# Internal: load bookmarks file
nav_bookmarks_load:
    cmp dword ptr [rip + g_data_ready], 0
    je .Lnbl_ret
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16384
    mov rdi, rsp
    lea rsi, [rip + g_data_dir]
    lea rdx, [rip + str_bm_file]
    mov ecx, PATH_MAX
    call path_join

    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lnbl_done
    mov ebx, eax
    lea r12, [rsp + PATH_MAX]
    mov edi, ebx
    mov rsi, r12
    mov edx, 16383
    call sys_read_retry
    mov r13, rax
    mov edi, ebx
    OS_CLOSE
    test r13, r13
    jle .Lnbl_done
    mov byte ptr [r12 + r13], 0

    mov rbx, r12
.Lnbl_line:
    cmp byte ptr [rbx], 0
    je .Lnbl_done
    cmp dword ptr [rip + g_bm_cnt], BM_MAX
    jge .Lnbl_done
    mov r13, rbx
.Lnbl_eol:
    mov al, [rbx]
    test al, al
    jz .Lnbl_got
    cmp al, '\n'
    je .Lnbl_term
    inc rbx
    jmp .Lnbl_eol
.Lnbl_term:
    mov byte ptr [rbx], 0
    inc rbx
.Lnbl_got:
    cmp byte ptr [r13], 0
    je .Lnbl_line
    mov rdi, r13
    call nav_strdup
    test rax, rax
    jz .Lnbl_line
    mov ecx, [rip + g_bm_cnt]
    lea rdx, [rip + g_bm_ptrs]
    mov [rdx + rcx*8], rax
    inc ecx
    mov [rip + g_bm_cnt], ecx
    jmp .Lnbl_line

.Lnbl_done:
    add rsp, PATH_MAX + 16384
    pop r13
    pop r12
    pop rbx
.Lnbl_ret:
    ret

# Internal: save bookmarks file
nav_bookmarks_save:
    cmp dword ptr [rip + g_data_ready], 0
    je .Lnbs_ret
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX * 2 + 16
    mov rdi, rsp
    lea rsi, [rip + g_data_dir]
    lea rdx, [rip + str_bm_file]
    mov ecx, PATH_MAX
    call path_join
    test rax, rax
    js .Lnbs_done

    mov rdi, rsp
    lea rsi, [rsp + PATH_MAX]
    mov edx, 0644
    call tmp_open_atomic
    test rax, rax
    js .Lnbs_done
    mov ebx, eax
    xor r12d, r12d
    xor r13d, r13d
.Lnbs_loop:
    cmp r12d, [rip + g_bm_cnt]
    jge .Lnbs_close
    lea rcx, [rip + g_bm_ptrs]
    mov rdi, [rcx + r12*8]
    test rdi, rdi
    jz .Lnbs_next
    push rdi
    call str_len
    pop rsi
    mov rdx, rax
    mov edi, ebx
    call sys_write_all
    test rax, rax
    js .Lnbs_werr
    mov byte ptr [rsp + PATH_MAX * 2], '\n'
    mov edi, ebx
    lea rsi, [rsp + PATH_MAX * 2]
    mov edx, 1
    call sys_write_all
    test rax, rax
    jns .Lnbs_next
.Lnbs_werr:
    mov r13, rax
    jmp .Lnbs_close
.Lnbs_next:
    inc r12d
    jmp .Lnbs_loop
.Lnbs_close:
    mov edi, ebx
    lea rsi, [rsp + PATH_MAX]
    mov rdx, rsp
    mov rcx, r13
    call tmp_commit_atomic
.Lnbs_done:
    add rsp, PATH_MAX * 2 + 16
    pop r13
    pop r12
    pop rbx
.Lnbs_ret:
    ret

# int nav_bookmarks_count(void)
nav_bookmarks_count:
    mov eax, [rip + g_bm_cnt]
    ret

# const char *nav_bookmarks_get(int idx)
nav_bookmarks_get:
    cmp edi, 0
    jl .Lnbg_none
    cmp edi, [rip + g_bm_cnt]
    jge .Lnbg_none
    lea rcx, [rip + g_bm_ptrs]
    mov rax, [rcx + rdi*8]
    ret
.Lnbg_none:
    xor eax, eax
    ret

# int nav_bookmarks_add(const char *path) -- returns 1 if added, 0 if dup/full
nav_bookmarks_add:
    test rdi, rdi
    jz .Lnba_zero
    cmp byte ptr [rdi], 0
    je .Lnba_zero
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
.Lnba_chk:
    cmp r12d, [rip + g_bm_cnt]
    jge .Lnba_ins
    lea rcx, [rip + g_bm_ptrs]
    mov rdi, [rcx + r12*8]
    mov rsi, rbx
    call str_cmp
    test eax, eax
    jz .Lnba_dup
    inc r12d
    jmp .Lnba_chk
.Lnba_ins:
    cmp dword ptr [rip + g_bm_cnt], BM_MAX
    jge .Lnba_dup
    mov rdi, rbx
    call nav_strdup
    test rax, rax
    jz .Lnba_dup
    mov ecx, [rip + g_bm_cnt]
    lea rdx, [rip + g_bm_ptrs]
    mov [rdx + rcx*8], rax
    inc ecx
    mov [rip + g_bm_cnt], ecx
    call nav_bookmarks_save
    mov eax, 1
    pop r12
    pop rbx
    ret
.Lnba_dup:
    xor eax, eax
    pop r12
    pop rbx
    ret
.Lnba_zero:
    xor eax, eax
    ret

# void nav_bookmarks_remove(int idx)
nav_bookmarks_remove:
    cmp edi, 0
    jl .Lnbr_ret
    cmp edi, [rip + g_bm_cnt]
    jge .Lnbr_ret
    push rbx
    mov ebx, edi
    lea rcx, [rip + g_bm_ptrs]
    mov rdi, [rcx + rbx*8]
    test rdi, rdi
    jz .Lnbr_sh
    call mem_free
.Lnbr_sh:
    mov ecx, ebx
    mov edx, [rip + g_bm_cnt]
    dec edx
    lea r8, [rip + g_bm_ptrs]
.Lnbr_loop:
    cmp ecx, edx
    jge .Lnbr_done
    mov rax, [r8 + rcx*8 + 8]
    mov [r8 + rcx*8], rax
    inc ecx
    jmp .Lnbr_loop
.Lnbr_done:
    mov [rip + g_bm_cnt], edx
    call nav_bookmarks_save
    pop rbx
.Lnbr_ret:
    ret
