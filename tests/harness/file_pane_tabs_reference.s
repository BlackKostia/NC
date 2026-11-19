# Frozen reference oracle: src/ui/file_pane_tabs.s (before C23 migration to src/ui/file_pane_tabs.c).
# FilePane Widget (Inherits from Widget) — file pane tabs (split from file_pane.s)

.intel_syntax noprefix
.include "classes.inc"
.equ FP_TAB_MAX,       8
.equ FP_TAB_PATH,      0
.equ FP_TAB_CURSOR,    4096
.equ FP_TAB_SCROLL,    4100
.equ FP_TAB_SORT_MODE, 4104
.equ FP_TAB_SORT_DESC, 4108
.equ FP_TAB_SHOW_HID,  4112
.equ FP_TAB_SIZE,      4384

.section .text
.global fp_get_active_tab
.global FilePane_nav_to
.global FilePane_hist_back
.global FilePane_hist_fwd
.global FilePane_tab_new
.global FilePane_tab_switch
.global FilePane_tab_close

# ==============================================================================
# Tab & Navigation History Helpers (ROADMAP 1.3)
# ==============================================================================

# Internal: void *fp_get_active_tab(FilePane *this)
fp_get_active_tab:
    mov rax, [rdi + FilePane.tabs]
    test rax, rax
    jz .Lfgat_none
    mov ecx, [rdi + FilePane.active_tab]
    cmp ecx, 0
    jl .Lfgat_none
    cmp ecx, [rdi + FilePane.tab_count]
    jge .Lfgat_none
    imul rcx, rcx, FP_TAB_SIZE
    add rax, rcx
    ret
.Lfgat_none:
    xor eax, eax
    ret

# Internal: void fp_save_tab(FilePane *this)
fp_save_tab:
    push rbx
    mov rbx, rdi
    call fp_get_active_tab
    test rax, rax
    jz .Lfst_ret
    mov rcx, [rbx + FilePane.model]
    mov edx, [rbx + FilePane.cursor]
    mov [rax + FP_TAB_CURSOR], edx
    mov edx, [rbx + FilePane.scroll]
    mov [rax + FP_TAB_SCROLL], edx
    mov edx, [rcx + DirModel.sort_mode]
    mov [rax + FP_TAB_SORT_MODE], edx
    mov edx, [rcx + DirModel.sort_desc]
    mov [rax + FP_TAB_SORT_DESC], edx
    mov edx, [rcx + DirModel.show_hidden]
    mov [rax + FP_TAB_SHOW_HID], edx
    mov rdi, rax
    lea rsi, [rcx + DirModel.path]
    mov edx, PATH_MAX
    call str_copy
.Lfst_ret:
    pop rbx
    ret

# int FilePane_nav_to(FilePane *this, const char *path) -- returns DirModel_chdir result
FilePane_nav_to:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + FilePane.model]
    mov rsi, r12
    call DirModel_chdir; test rax, rax; js .Lfnt_ret
    mov rdi, [rbx + FilePane.model]; cmp dword ptr [rdi + DirModel.du_mode], 0; je .Lfnt_cur; call dir_du_populate
.Lfnt_cur:
    mov dword ptr [rbx + FilePane.cursor], 0; mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx; call FilePane_ensure_visible
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfnt_rec
    mov rdi, rax
    mov rcx, [rbx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    call nav_hist_push
.Lfnt_rec:
    mov rcx, [rbx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    call nav_frecency_record
    xor eax, eax
.Lfnt_ret:
    pop r12
    pop rbx
    ret

# int FilePane_hist_back(FilePane *this) -- returns 1 if navigated, 0 if empty
FilePane_hist_back:
    push rbx
    mov rbx, rdi
    call fp_get_active_tab
    test rax, rax
    jz .Lfhb_no
    mov rdi, rax
    call nav_hist_back
    test rax, rax
    jz .Lfhb_no
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    call DirModel_chdir
    test rax, rax
    js .Lfhb_no
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible
    mov eax, 1
    pop rbx
    ret
.Lfhb_no:
    xor eax, eax
    pop rbx
    ret

# int FilePane_hist_fwd(FilePane *this) -- returns 1 if navigated, 0 if empty
FilePane_hist_fwd:
    push rbx
    mov rbx, rdi
    call fp_get_active_tab
    test rax, rax
    jz .Lfhf_no
    mov rdi, rax
    call nav_hist_fwd
    test rax, rax
    jz .Lfhf_no
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    call DirModel_chdir
    test rax, rax
    js .Lfhf_no
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible
    mov eax, 1
    pop rbx
    ret
.Lfhf_no:
    xor eax, eax
    pop rbx
    ret

# int FilePane_tab_new(FilePane *this) -- returns 1 if opened, 0 if at limit
FilePane_tab_new:
    push rbx
    push r12
    mov rbx, rdi
    mov eax, [rbx + FilePane.tab_count]
    cmp eax, FP_TAB_MAX
    jge .Lftn_full
    call fp_save_tab
    mov r12d, [rbx + FilePane.tab_count]
    imul rcx, r12, FP_TAB_SIZE
    add rcx, [rbx + FilePane.tabs]
    push rcx
    mov rdi, rcx
    mov rsi, FP_TAB_SIZE
    call mem_zero
    pop rcx
    mov rax, [rbx + FilePane.model]
    lea rsi, [rax + DirModel.path]
    mov rdi, rcx
    mov edx, PATH_MAX
    push rcx
    call str_copy
    pop rcx
    mov rax, [rbx + FilePane.model]
    lea rsi, [rax + DirModel.path]
    mov rdi, rcx
    call nav_hist_push
    mov [rbx + FilePane.active_tab], r12d
    inc dword ptr [rbx + FilePane.tab_count]
    mov eax, 1
    pop r12
    pop rbx
    ret
.Lftn_full:
    xor eax, eax
    pop r12
    pop rbx
    ret

# int FilePane_tab_switch(FilePane *this, int idx)
FilePane_tab_switch:
    cmp esi, 0
    jl .Lfts_no
    cmp esi, [rdi + FilePane.tab_count]
    jge .Lfts_no
    cmp esi, [rdi + FilePane.active_tab]
    je .Lfts_ok
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    call fp_save_tab
    mov [rbx + FilePane.active_tab], r12d
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfts_done
    mov rcx, [rbx + FilePane.model]
    mov edx, [rax + FP_TAB_SORT_MODE]
    mov [rcx + DirModel.sort_mode], edx
    mov edx, [rax + FP_TAB_SORT_DESC]
    mov [rcx + DirModel.sort_desc], edx
    mov edx, [rax + FP_TAB_SHOW_HID]
    mov [rcx + DirModel.show_hidden], edx
    push rax
    mov rdi, rcx
    lea rsi, [rax + FP_TAB_PATH]
    call DirModel_chdir
    pop rax
    mov edx, [rax + FP_TAB_CURSOR]
    mov [rbx + FilePane.cursor], edx
    mov edx, [rax + FP_TAB_SCROLL]
    mov [rbx + FilePane.scroll], edx
    mov rdi, rbx
    call FilePane_ensure_visible
.Lfts_done:
    pop r12
    pop rbx
.Lfts_ok:
    mov eax, 1
    ret
.Lfts_no:
    xor eax, eax
    ret

# int FilePane_tab_close(FilePane *this, int idx_or_neg1)
FilePane_tab_close:
    cmp dword ptr [rdi + FilePane.tab_count], 1
    jle .Lftc_last
    push rbx
    push r12
    push r13
    call FilePane_tab_close__part1
    cmp r12d, [rbx + FilePane.tab_count]
    jge .Lftc_fail

    # Free history strings in tab r12d
    call FilePane_tab_close__free_history_strings_tab
    call FilePane_tab_close__fp_get_active_tab
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.Lftc_fail:
    pop r13
    pop r12
    pop rbx
.Lftc_last:
    xor eax, eax
    ret

# FilePane_tab_close step (runs on the caller's frame)
FilePane_tab_close__part1:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, 0
    jge .Lftc_chk
    mov r12d, [rbx + FilePane.active_tab]
.Lftc_chk:
.LFilePane_tab_close__part1_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_tab_close step: Free history strings in tab r12d (runs on the caller's frame)
FilePane_tab_close__free_history_strings_tab:
    lea rsp, [rsp - 8]
    imul rax, r12, FP_TAB_SIZE
    add rax, [rbx + FilePane.tabs]
    xor ecx, ecx
.Lftc_fh:
    cmp ecx, [rax + 4120]     # TAB_HIST_LEN
    jge .Lftc_shift
    push rax
    push rcx
    mov rdi, [rax + 4128 + rcx*8]
    test rdi, rdi
    jz .Lftc_fh_n
    call mem_free
.Lftc_fh_n:
    pop rcx
    pop rax
    inc ecx
    jmp .Lftc_fh

.Lftc_shift:
    mov r13d, r12d
    mov edx, [rbx + FilePane.tab_count]
    dec edx
.Lftc_sh_loop:
    cmp r13d, edx
    jge .Lftc_dec
    imul rdi, r13, FP_TAB_SIZE
    add rdi, [rbx + FilePane.tabs]
    lea rsi, [rdi + FP_TAB_SIZE]
    push rdx
    mov rdx, FP_TAB_SIZE
    call mem_copy
    pop rdx
    inc r13d
    jmp .Lftc_sh_loop

.Lftc_dec:
.LFilePane_tab_close__free_history_strings_tab_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_tab_close step: fp_get_active_tab (runs on the caller's frame)
FilePane_tab_close__fp_get_active_tab:
    lea rsp, [rsp - 8]
    dec dword ptr [rbx + FilePane.tab_count]
    mov eax, [rbx + FilePane.active_tab]
    cmp eax, r12d
    jl .Lftc_ret1
    je .Lftc_reload
    dec dword ptr [rbx + FilePane.active_tab]
    jmp .Lftc_ret1

.Lftc_reload:
    mov eax, [rbx + FilePane.active_tab]
    cmp eax, [rbx + FilePane.tab_count]
    jl .Lftc_rel_go
    dec eax
    mov [rbx + FilePane.active_tab], eax
.Lftc_rel_go:
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lftc_ret1
    mov rdi, [rbx + FilePane.model]
    lea rsi, [rax + FP_TAB_PATH]
    push rax
    call DirModel_chdir
    pop rax
    mov edx, [rax + FP_TAB_CURSOR]
    mov [rbx + FilePane.cursor], edx
    mov edx, [rax + FP_TAB_SCROLL]
    mov [rbx + FilePane.scroll], edx
    mov rdi, rbx
    call FilePane_ensure_visible

.Lftc_ret1:
.LFilePane_tab_close__fp_get_active_tab_ret:
    lea rsp, [rsp + 8]
    ret
