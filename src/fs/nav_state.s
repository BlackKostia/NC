# Duop Navigation State: Per-tab History, Bookmarks (Hotlist) & Frecency (z)
# Pure x86-64 GAS, zero .data, PAL-clean (uses OS_* macros only).

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

.section .rodata
env_xdg_data:   .asciz "XDG_DATA_HOME="
env_home:       .asciz "HOME="
str_local_share: .asciz ".local/share"
str_duop_dir:   .asciz "duop"
str_bm_file:    .asciz "bookmarks"
str_fre_file:   .asciz "frecency"

.section .bss
.align 8
g_data_dir:     .space PATH_MAX
g_data_ready:   .space 4
g_bm_cnt:       .space 4
g_fre_cnt:      .space 4
g_bm_pad:       .space 4
g_bm_ptrs:      .space BM_MAX * 8
g_fre_scores:   .space FRE_MAX * 4
g_fre_ptrs:     .space FRE_MAX * 8

.section .text
.global nav_tabs_alloc
.global nav_tabs_free
.global nav_hist_push
.global nav_hist_back
.global nav_hist_fwd
.global nav_state_init
.global nav_bookmarks_count
.global nav_bookmarks_get
.global nav_bookmarks_add
.global nav_bookmarks_remove
.global nav_frecency_record
.global nav_frecency_count
.global nav_frecency_get
.global nav_frecency_score
.global nav_frecency_match

# Internal: char *nav_strdup(const char *s)
nav_strdup:
    push rbx
    push r12
    mov rbx, rdi
    call str_len
    lea r12, [rax + 1]
    mov rdi, r12
    call mem_alloc
    test rax, rax
    jz .Lnsd_ret
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    push rax
    call str_copy
    pop rax
.Lnsd_ret:
    pop r12
    pop rbx
    ret

# Internal: const char *nav_find_env(char **envp, const char *prefix)
nav_find_env:
    test rdi, rdi
    jz .Lnfe_none
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call str_len
    mov r13, rax
.Lnfe_loop:
    mov rsi, [rbx]
    test rsi, rsi
    jz .Lnfe_notfound
    xor ecx, ecx
.Lnfe_cmp:
    cmp rcx, r13
    je .Lnfe_hit
    mov al, [rsi + rcx]
    cmp al, [r12 + rcx]
    jne .Lnfe_next
    inc rcx
    jmp .Lnfe_cmp
.Lnfe_hit:
    lea rax, [rsi + r13]
    pop r13
    pop r12
    pop rbx
    ret
.Lnfe_next:
    add rbx, 8
    jmp .Lnfe_loop
.Lnfe_notfound:
    pop r13
    pop r12
    pop rbx
.Lnfe_none:
    xor eax, eax
    ret

# Internal: void nav_mkdir_p(const char *path)
nav_mkdir_p:
    push rbx
    sub rsp, PATH_MAX + 8
    mov rsi, rdi
    mov rdi, rsp
    mov edx, PATH_MAX
    call str_copy
    lea rbx, [rsp + 1]
.Lnmp_loop:
    mov al, [rbx]
    test al, al
    jz .Lnmp_last
    cmp al, '/'
    jne .Lnmp_next
    mov byte ptr [rbx], 0
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, 0755
    OS_MKDIRAT
    mov byte ptr [rbx], '/'
.Lnmp_next:
    inc rbx
    jmp .Lnmp_loop
.Lnmp_last:
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, 0755
    OS_MKDIRAT
    add rsp, PATH_MAX + 8
    pop rbx
    ret

# Internal: ASCII case-insensitive substring match: int nav_ci_contains(const char *hay, const char *needle)
nav_ci_contains:
    cmp byte ptr [rsi], 0
    je .Lncc_yes
.Lncc_outer:
    mov al, [rdi]
    test al, al
    jz .Lncc_no
    xor ecx, ecx
.Lncc_inner:
    mov dl, [rsi + rcx]
    test dl, dl
    jz .Lncc_yes
    mov al, [rdi + rcx]
    test al, al
    jz .Lncc_no
    cmp al, 'A'
    jb .Lncc_a_ok
    cmp al, 'Z'
    ja .Lncc_a_ok
    add al, 32
.Lncc_a_ok:
    cmp dl, 'A'
    jb .Lncc_d_ok
    cmp dl, 'Z'
    ja .Lncc_d_ok
    add dl, 32
.Lncc_d_ok:
    cmp al, dl
    jne .Lncc_adv
    inc rcx
    jmp .Lncc_inner
.Lncc_adv:
    inc rdi
    jmp .Lncc_outer
.Lncc_yes:
    mov eax, 1
    ret
.Lncc_no:
    xor eax, eax
    ret

# void *nav_tabs_alloc(const char *init_path)
nav_tabs_alloc:
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, TAB_MAX * TAB_SIZE
    call mem_alloc
    test rax, rax
    jz .Lnta_ret
    mov r12, rax
    mov rdi, r12
    mov rsi, TAB_MAX * TAB_SIZE
    call mem_zero
    test rbx, rbx
    jz .Lnta_done
    lea rdi, [r12 + TAB_PATH]
    mov rsi, rbx
    mov edx, PATH_MAX
    call str_copy
    mov rdi, rbx
    call nav_strdup
    mov [r12 + TAB_HIST_PTRS], rax
    test rax, rax
    jz .Lnta_done
    mov dword ptr [r12 + TAB_HIST_LEN], 1
    mov dword ptr [r12 + TAB_HIST_POS], 0
.Lnta_done:
    mov rax, r12
.Lnta_ret:
    pop r12
    pop rbx
    ret

# void nav_tabs_free(void *tabs, int tab_count)
nav_tabs_free:
    test rdi, rdi
    jz .Lntf_ret
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d
.Lntf_tab:
    cmp r13d, r12d
    jge .Lntf_free_arr
    imul rax, r13, TAB_SIZE
    lea r14, [rbx + rax]
    xor ecx, ecx
.Lntf_h:
    cmp ecx, [r14 + TAB_HIST_LEN]
    jge .Lntf_next_tab
    push rcx
    mov rdi, [r14 + TAB_HIST_PTRS + rcx*8]
    test rdi, rdi
    jz .Lntf_h_next
    call mem_free
.Lntf_h_next:
    pop rcx
    inc ecx
    jmp .Lntf_h
.Lntf_next_tab:
    inc r13d
    jmp .Lntf_tab
.Lntf_free_arr:
    mov rdi, rbx
    call mem_free
    pop r14
    pop r13
    pop r12
    pop rbx
.Lntf_ret:
    ret

# void nav_hist_push(void *tab, const char *path)
nav_hist_push:
    test rdi, rdi
    jz .Lnhp_ret
    test rsi, rsi
    jz .Lnhp_ret
    cmp byte ptr [rsi], 0
    je .Lnhp_ret
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi

    # Skip if equal to current history head
    mov eax, [rbx + TAB_HIST_LEN]
    test eax, eax
    jz .Lnhp_append
    mov ecx, [rbx + TAB_HIST_POS]
    cmp ecx, eax
    jae .Lnhp_append
    mov rdi, [rbx + TAB_HIST_PTRS + rcx*8]
    test rdi, rdi
    jz .Lnhp_trunc
    mov rsi, r12
    call str_cmp
    test eax, eax
    jz .Lnhp_done

.Lnhp_trunc:
    mov r13d, [rbx + TAB_HIST_POS]
    inc r13d
.Lnhp_trunc_loop:
    cmp r13d, [rbx + TAB_HIST_LEN]
    jge .Lnhp_trunc_done
    mov rdi, [rbx + TAB_HIST_PTRS + r13*8]
    test rdi, rdi
    jz .Lnhp_trunc_next
    call mem_free
    mov qword ptr [rbx + TAB_HIST_PTRS + r13*8], 0
.Lnhp_trunc_next:
    inc r13d
    jmp .Lnhp_trunc_loop
.Lnhp_trunc_done:
    mov eax, [rbx + TAB_HIST_POS]
    inc eax
    mov [rbx + TAB_HIST_LEN], eax

.Lnhp_append:
    mov eax, [rbx + TAB_HIST_LEN]
    cmp eax, HIST_MAX
    jl .Lnhp_store
    # Drop oldest entry [0] and shift left
    mov rdi, [rbx + TAB_HIST_PTRS]
    test rdi, rdi
    jz .Lnhp_shift
    call mem_free
.Lnhp_shift:
    xor ecx, ecx
.Lnhp_sh_loop:
    cmp ecx, HIST_MAX - 1
    jge .Lnhp_sh_done
    mov rax, [rbx + TAB_HIST_PTRS + rcx*8 + 8]
    mov [rbx + TAB_HIST_PTRS + rcx*8], rax
    inc ecx
    jmp .Lnhp_sh_loop
.Lnhp_sh_done:
    mov dword ptr [rbx + TAB_HIST_LEN], HIST_MAX - 1

.Lnhp_store:
    mov rdi, r12
    call nav_strdup
    test rax, rax
    jz .Lnhp_done
    mov ecx, [rbx + TAB_HIST_LEN]
    mov [rbx + TAB_HIST_PTRS + rcx*8], rax
    mov [rbx + TAB_HIST_POS], ecx
    inc ecx
    mov [rbx + TAB_HIST_LEN], ecx

.Lnhp_done:
    pop r13
    pop r12
    pop rbx
.Lnhp_ret:
    ret

# const char *nav_hist_back(void *tab)
nav_hist_back:
    test rdi, rdi
    jz .Lnhb_none
    mov eax, [rdi + TAB_HIST_POS]
    test eax, eax
    jle .Lnhb_none
    dec eax
    mov [rdi + TAB_HIST_POS], eax
    mov rax, [rdi + TAB_HIST_PTRS + rax*8]
    ret
.Lnhb_none:
    xor eax, eax
    ret

# const char *nav_hist_fwd(void *tab)
nav_hist_fwd:
    test rdi, rdi
    jz .Lnhf_none
    mov eax, [rdi + TAB_HIST_POS]
    inc eax
    cmp eax, [rdi + TAB_HIST_LEN]
    jge .Lnhf_none
    mov [rdi + TAB_HIST_POS], eax
    mov rax, [rdi + TAB_HIST_PTRS + rax*8]
    ret
.Lnhf_none:
    xor eax, eax
    ret

# Internal: write uint32 decimal + ' ' to buf; returns bytes written
nav_u32_to_str:
    # edi=val, rsi=buf
    push rbx
    mov eax, edi
    mov rbx, rsi
    sub rsp, 16
    xor ecx, ecx
.Lnus_div:
    xor edx, edx
    mov r8d, 10
    div r8d
    add dl, '0'
    mov [rsp + rcx], dl
    inc ecx
    test eax, eax
    jnz .Lnus_div
    xor eax, eax
.Lnus_rev:
    dec ecx
    mov dl, [rsp + rcx]
    mov [rbx + rax], dl
    inc eax
    test ecx, ecx
    jnz .Lnus_rev
    add rsp, 16
    pop rbx
    ret

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
    sub rsp, PATH_MAX + 8
    mov rdi, rsp
    lea rsi, [rip + g_data_dir]
    lea rdx, [rip + str_bm_file]
    mov ecx, PATH_MAX
    call path_join

    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0644
    OS_OPENAT
    test rax, rax
    js .Lnbs_done
    mov ebx, eax
    xor r12d, r12d
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
    mov byte ptr [rsp + PATH_MAX], '\n'
    mov edi, ebx
    lea rsi, [rsp + PATH_MAX]
    mov edx, 1
    call sys_write_all
.Lnbs_next:
    inc r12d
    jmp .Lnbs_loop
.Lnbs_close:
    mov edi, ebx
    OS_CLOSE
.Lnbs_done:
    add rsp, PATH_MAX + 8
    pop r12
    pop rbx
.Lnbs_ret:
    ret

# Internal: load frecency file ("<score> <path>\n")
nav_frecency_load:
    cmp dword ptr [rip + g_data_ready], 0
    je .Lnfl_ret
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16384
    mov rdi, rsp
    lea rsi, [rip + g_data_dir]
    lea rdx, [rip + str_fre_file]
    mov ecx, PATH_MAX
    call path_join

    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lnfl_done
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
    jle .Lnfl_done
    mov byte ptr [r12 + r13], 0

    mov rbx, r12
.Lnfl_line:
    cmp byte ptr [rbx], 0
    je .Lnfl_done
    cmp dword ptr [rip + g_fre_cnt], FRE_MAX
    jge .Lnfl_done
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

.Lnfl_done:
    add rsp, PATH_MAX + 16384
    pop r13
    pop r12
    pop rbx
.Lnfl_ret:
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

# void nav_state_init(char **envp)
nav_state_init:
    push rbx
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    mov dword ptr [rip + g_data_ready], 0
    mov dword ptr [rip + g_bm_cnt], 0
    mov dword ptr [rip + g_fre_cnt], 0

    mov rdi, rbx
    lea rsi, [rip + env_xdg_data]
    call nav_find_env
    test rax, rax
    jz .Lnsi_home
    cmp byte ptr [rax], 0
    je .Lnsi_home
    lea rdi, [rip + g_data_dir]
    mov rsi, rax
    lea rdx, [rip + str_duop_dir]
    mov ecx, PATH_MAX
    call path_join
    jmp .Lnsi_mk

.Lnsi_home:
    mov rdi, rbx
    lea rsi, [rip + env_home]
    call nav_find_env
    test rax, rax
    jz .Lnsi_done
    cmp byte ptr [rax], 0
    je .Lnsi_done
    mov rdi, rsp
    mov rsi, rax
    lea rdx, [rip + str_local_share]
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rip + g_data_dir]
    mov rsi, rsp
    lea rdx, [rip + str_duop_dir]
    mov ecx, PATH_MAX
    call path_join

.Lnsi_mk:
    lea rdi, [rip + g_data_dir]
    call nav_mkdir_p
    mov dword ptr [rip + g_data_ready], 1
    call nav_bookmarks_load
    call nav_frecency_load

.Lnsi_done:
    add rsp, PATH_MAX + 8
    pop rbx
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
    lea r8, [rip + g_fre_scores]
    lea r9, [rip + g_fre_ptrs]
.Lnfr_bub_loop:
    test r12d, r12d
    jle .Lnfr_save
    lea ecx, [r12d - 1]
    mov eax, [r8 + r12*4]
    mov edx, [r8 + rcx*4]
    cmp eax, edx
    jle .Lnfr_save
    mov [r8 + r12*4], edx
    mov [r8 + rcx*4], eax
    mov rax, [r9 + r12*8]
    mov rdx, [r9 + rcx*8]
    mov [r9 + r12*8], rdx
    mov [r9 + rcx*8], rax
    mov r12d, ecx
    jmp .Lnfr_bub_loop

.Lnfr_save:
    call nav_frecency_save
    pop r12
    pop rbx
.Lnfr_ret:
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
