# FilePane Widget (Inherits from Widget)
# Full-featured file list panel: TrueColor styling, adaptive columns, interactive
# column-header sorting, double-click open, right-click mark, wheel & drag scrollbar.

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

.section .rodata
str_FilePane:    .asciz "FilePane"
str_dotdot_fp:   .asciz ".."

FilePane_vtbl:
    WIDGET_VTBL_SLOTS str_FilePane, Widget_vtbl, FilePane._size, FilePane_dtor, FilePane_layout, FilePane_render, FilePane_on_key, FilePane_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global FilePane_new
.global FilePane_dtor
.global get_list_h
.global FilePane_ensure_visible
.global FilePane_get_selected_entry
.global FilePane_reload_keep_cursor
.global FilePane_enter_parent
.global compute_cols
.global FilePane_vtbl

# FilePane *FilePane_new(App *app, const char *initial_path, int id)
FilePane_new:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi              # app
    mov r13, rsi              # initial_path
    mov r14d, edx             # id

    NEW_OBJ FilePane_vtbl, FilePane._size
    test rax, rax
    jz .Lfpn_fail
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    call Widget_init

    mov [rbx + FilePane.app], r12
    mov dword ptr [rbx + FilePane.last_click_idx], -1
    mov dword ptr [rbx + FilePane.hovered_row], -1
    mov dword ptr [rbx + FilePane.hovered_col_hdr], -1

    mov rdi, r13
    call DirModel_new
    test rax, rax
    jz .Lfpn_fail_free
    mov [rbx + FilePane.model], rax

    lea rdi, [rax + DirModel.path]
    call nav_tabs_alloc
    mov [rbx + FilePane.tabs], rax
    mov dword ptr [rbx + FilePane.tab_count], 1
    mov dword ptr [rbx + FilePane.active_tab], 0

    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.Lfpn_fail_free:
    mov rdi, rbx
    call mem_free
.Lfpn_fail:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void FilePane_dtor(FilePane *this)
FilePane_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + FilePane.tabs]
    mov esi, [rbx + FilePane.tab_count]
    call nav_tabs_free
    mov qword ptr [rbx + FilePane.tabs], 0
    mov rdi, [rbx + FilePane.model]
    DELETE_OBJ rdi
    mov qword ptr [rbx + FilePane.model], 0
    pop rbx
    ret

# Helper: int get_list_h(FilePane *this)
get_list_h:
    mov eax, [rdi + Widget.h]
    sub eax, 5
    cmp eax, 1
    jge .Lglh_ok
    mov eax, 1
.Lglh_ok:
    ret

# void FilePane_ensure_visible(FilePane *this)
FilePane_ensure_visible:
    mov rcx, [rdi + FilePane.model]
    mov rdx, [rcx + DirModel.count]
    test rdx, rdx
    jnz .Lfev_nonempty
    mov dword ptr [rdi + FilePane.cursor], 0
    mov dword ptr [rdi + FilePane.scroll], 0
    ret
.Lfev_nonempty:
    mov eax, [rdi + FilePane.cursor]
    test eax, eax
    jns .Lfev_c_nonneg
    xor eax, eax
.Lfev_c_nonneg:
    cmp rax, rdx
    jb .Lfev_c_ok
    lea eax, [edx - 1]
.Lfev_c_ok:
    mov [rdi + FilePane.cursor], eax

    call get_list_h           # eax = list_h
    mov r8d, eax
    mov eax, [rdi + FilePane.cursor]
    mov r9d, [rdi + FilePane.scroll]

    cmp eax, r9d
    jge .Lfev_chk_bot
    mov r9d, eax
    jmp .Lfev_clamp_scroll
.Lfev_chk_bot:
    lea r10d, [r9d + r8d]
    cmp eax, r10d
    jl .Lfev_clamp_scroll
    mov r9d, eax
    sub r9d, r8d
    inc r9d
.Lfev_clamp_scroll:
    # Clamp scroll <= max(0, count - list_h)
    mov eax, edx
    sub eax, r8d
    test eax, eax
    jns .Lfev_max_ok
    xor eax, eax
.Lfev_max_ok:
    cmp r9d, eax
    jle .Lfev_s_nonneg
    mov r9d, eax
.Lfev_s_nonneg:
    test r9d, r9d
    jns .Lfev_done
    xor r9d, r9d
.Lfev_done:
    mov [rdi + FilePane.scroll], r9d
    ret

# FileEntry *FilePane_get_selected_entry(FilePane *this)
FilePane_get_selected_entry:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, [rdi + FilePane.model]
    mov esi, [rdi + FilePane.cursor]
    mov rdi, rbx
    call DirModel_get_entry
    test rax, rax
    jz .Lfpge_done
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call DirModel_ensure_entry_stat
    mov rax, r12
.Lfpge_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# void FilePane_reload_keep_cursor(FilePane *this, const char *focus_name_or_null)
FilePane_reload_keep_cursor:
    push rbx
    push r12
    sub rsp, NAME_MAX + 16
    mov rbx, rdi
    mov r12, rsi

    test r12, r12
    jnz .Lfrkc_have_name
    mov rdi, rbx
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lfrkc_reload
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, rsp
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy
    mov r12, rsp
    jmp .Lfrkc_reload

.Lfrkc_have_name:
    mov rdi, rsp
    mov rsi, r12
    mov edx, NAME_MAX
    call str_copy
    mov r12, rsp

.Lfrkc_reload:
    mov rdi, [rbx + FilePane.model]
    call DirModel_reload

    test r12, r12
    jz .Lfrkc_vis
    mov rdi, [rbx + FilePane.model]
    mov rsi, r12
    call DirModel_find_by_name
    cmp rax, 0
    jl .Lfrkc_vis
    mov [rbx + FilePane.cursor], eax

.Lfrkc_vis:
    mov rdi, rbx
    call FilePane_ensure_visible
    add rsp, NAME_MAX + 16
    pop r12
    pop rbx
    ret

# void FilePane_enter_parent(FilePane *this)
# Navigates to parent directory and selects the child directory we just came from.
FilePane_enter_parent:
    push rbx
    sub rsp, NAME_MAX + 16
    mov rbx, rdi
    call fp_exit_virtual
    test eax, eax
    jnz .Lfep_done
    mov rcx, [rbx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    cmp byte ptr [rdi], '/'
    jne .Lfep_go
    cmp byte ptr [rdi + 1], 0
    je .Lfep_done             # already at root "/"

.Lfep_go:
    call path_basename
    mov rdi, rsp
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy

    mov rdi, [rbx + FilePane.model]
    lea rsi, [rip + str_dotdot_fp]
    call DirModel_chdir
    test rax, rax
    js .Lfep_done

    mov rdi, [rbx + FilePane.model]
    mov rsi, rsp
    call DirModel_find_by_name
    cmp rax, 0
    jge .Lfep_set_cur
    xor eax, eax
.Lfep_set_cur:
    mov [rbx + FilePane.cursor], eax
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible

    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfep_done
    mov rdi, rax
    mov rcx, [rbx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    push rsi
    call nav_hist_push
    pop rdi
    call nav_frecency_record
.Lfep_done:
    add rsp, NAME_MAX + 16
    pop rbx
    ret

# Helper: compute adaptive column layout into r8d=name_w, r9d=size_w, r10d=extra_w, r11d=extra_is_date(1)/perm(0)
compute_cols:
    mov eax, [rdi + Widget.w]
    sub eax, 2                # inner width
    cmp eax, 1
    jge .Lcc_ok
    mov eax, 1
.Lcc_ok:
    xor r9d, r9d              # size_w
    xor r10d, r10d            # extra_w
    xor r11d, r11d            # extra_is_date

    cmp dword ptr [rdi + Widget.w], 54
    jl .Lcc_chk_med
    mov r9d, 9
    mov r10d, 17              # 1 space + 16 date
    mov r11d, 1
    jmp .Lcc_name
.Lcc_chk_med:
    cmp dword ptr [rdi + Widget.w], 40
    jl .Lcc_chk_sm
    mov r9d, 9
    mov r10d, 11              # 1 space + 10 perms
    jmp .Lcc_name
.Lcc_chk_sm:
    cmp dword ptr [rdi + Widget.w], 28
    jl .Lcc_name
    mov r9d, 9
.Lcc_name:
    mov r8d, eax
    sub r8d, r9d
    sub r8d, r10d
    cmp r8d, 6
    jge .Lcc_ret
    mov r8d, eax
    xor r9d, r9d
    xor r10d, r10d
.Lcc_ret:
    ret
