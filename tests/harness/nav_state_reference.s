# Frozen reference oracle: the hand-written asm that src/fs/nav_state.c and nav_persist.c replaced (tests/test_c_nav_state.py diffs against it)
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

.section .bss
g_bm_pad:       .space 4

.section .rodata
env_xdg_data:   .asciz "XDG_DATA_HOME="
env_home:       .asciz "HOME="
str_local_share: .asciz ".local/share"
str_duop_dir:   .asciz "duop"

.section .text
.global nav_strdup
.global nav_ci_contains
.global nav_tabs_alloc
.global nav_tabs_free
.global nav_u32_to_str
.global nav_state_init
.global nav_state_cleanup

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

# void nav_state_init(char **envp)
nav_state_init:
    cmp dword ptr [rip + g_data_ready], 0
    jne .Lnsi_ret
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
.Lnsi_ret:
    ret

# void nav_state_cleanup(void) -- frees global bookmark & frecency string arrays
nav_state_cleanup:
    lea rdi, [rip + g_bm_ptrs]
    lea rsi, [rip + g_bm_cnt]
    call nav_free_ptr_array
    lea rdi, [rip + g_fre_ptrs]
    lea rsi, [rip + g_fre_cnt]
    # fall through

# void nav_free_ptr_array(void **ptrs, int *cnt)
nav_free_ptr_array:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, [rsi]
    mov dword ptr [rsi], 0
    xor r13d, r13d
.Lnfp_loop:
    cmp r13d, r12d
    jge .Lnfp_done
    mov rdi, [rbx + r13*8]
    mov qword ptr [rbx + r13*8], 0
    test rdi, rdi
    jz .Lnfp_next
    call mem_free
.Lnfp_next:
    inc r13d
    jmp .Lnfp_loop
.Lnfp_done:
    pop r13
    pop r12
    pop rbx
    ret
