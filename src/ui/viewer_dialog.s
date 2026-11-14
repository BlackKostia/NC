# ViewerDialog (Inherits from Dialog): built-in Text / Hex file viewer for files of ANY size
#
# Regular files are mapped read-only (no copy into RAM, no size cap, O(1) open); other files
# (pipes, /proc) fall back to a bounded heap read. Navigation is offset based (like `less`):
# the top line is a byte offset, moves scan to neighbouring newlines with SIMD, so cost never
# depends on the file size. Exact line numbers are kept incrementally; End counts newlines
# once with SIMD. A truncated-under-us mapping is protected by the PAL SIGBUS guard.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ VW_LINE_MAX, 248

.section .rodata
str_ViewerDialog: .asciz "ViewerDialog"

ViewerDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ViewerDialog, Dialog_vtbl, ViewerDialog._size, ViewerDialog_dtor, ViewerDialog_layout, ViewerDialog_render, ViewerDialog_on_key, ViewerDialog_on_mouse, Widget_on_focus, Widget_hit_test, ViewerDialog_on_btn0, Dialog_on_cancel

.section .text
.global ViewerDialog_new
.global ViewerDialog_dtor
.global ViewerDialog_layout
.global ViewerDialog_on_btn0
.global vw_line_up
.global vw_scroll
.global vw_home
.global ViewerDialog_vtbl

# ViewerDialog *ViewerDialog_new(App *app, const char *path)
ViewerDialog_new:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 56                       # FileStat
    mov r12, rdi
    mov r13, rsi

    NEW_OBJ ViewerDialog_vtbl, ViewerDialog._size
    test rax, rax
    jz .Lvdn_ret
    call ViewerDialog_new__regular_file_read_only
    # Binary when a NUL byte occurs in the first 512 bytes -> start in Hex mode
    call ViewerDialog_new__binary_when_nul_byte
    call ViewerDialog_new__layout
.Lvdn_ret:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ViewerDialog_new step: Regular file read only mapping of the whole file (runs on the caller's frame)
ViewerDialog_new__regular_file_read_only:
    lea rsp, [rsp - 8]
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_viewer]
    mov rdi, rbx
    mov rsi, r12
    xor ecx, ecx
    call Dialog_init
    mov dword ptr [rbx + Dialog.focus_btn], 1
    mov qword ptr [rbx + ViewerDialog.total_lines], -1
    lea rdi, [rbx + ViewerDialog.path]
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy

    # Regular file -> read-only mapping of the whole file
    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lvdn_fallback
    mov r14d, eax
    mov edi, r14d
    lea rsi, [rsp + 16]
    call os_fstat
    test rax, rax
    js .Lvdn_close
    mov eax, [rsp + FileStat.mode + 16]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Lvdn_close
    mov rsi, [rsp + FileStat.size + 16]
    test rsi, rsi
    jle .Lvdn_close
    mov edi, r14d
    call os_mmap_file_ro
    test rax, rax
    jz .Lvdn_close
    mov [rbx + ViewerDialog.data], rax
    mov rax, [rsp + FileStat.size + 16]
    mov [rbx + ViewerDialog.data_len], rax
    mov [rbx + ViewerDialog.map_len], rax
.Lvdn_close:
    mov edi, r14d
    OS_CLOSE
    cmp qword ptr [rbx + ViewerDialog.data], 0
    jne .Lvdn_detect
.Lvdn_fallback:
    mov rdi, r13
    mov esi, VIEWER_MAX_SIZE
    lea rdx, [rbx + ViewerDialog.data]
    lea rcx, [rbx + ViewerDialog.data_len]
    call fs_read_file_alloc

.Lvdn_detect:
.LViewerDialog_new__regular_file_read_only_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_new step: Binary when NUL byte occurs in the first bytes start in Hex mode (runs on the caller's frame)
ViewerDialog_new__binary_when_nul_byte:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + ViewerDialog.data]
    test rdi, rdi
    jz .Lvdn_layout
    mov rsi, [rbx + ViewerDialog.data_len]
    cmp rsi, 512
    jbe .Lvdn_scan
    mov esi, 512
.Lvdn_scan:
    xor edx, edx
    call os_mem_find_byte
    mov rsi, [rbx + ViewerDialog.data_len]
    cmp rsi, 512
    jbe .Lvdn_cmp
    mov esi, 512
.Lvdn_cmp:
    cmp rax, rsi
    jae .Lvdn_layout
    mov dword ptr [rbx + ViewerDialog.hex_mode], 1

.Lvdn_layout:
.LViewerDialog_new__binary_when_nul_byte_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_new step: layout (runs on the caller's frame)
ViewerDialog_new__layout:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call ViewerDialog_layout
    mov rax, rbx
.LViewerDialog_new__layout_ret:
    lea rsp, [rsp + 8]
    ret

# void ViewerDialog_dtor(ViewerDialog *this)
ViewerDialog_dtor:
    push rbx
    mov rbx, rdi
    call hex_edit_free
    mov rdi, [rbx + ViewerDialog.data]
    mov rsi, [rbx + ViewerDialog.map_len]
    test rsi, rsi
    jz .Lvdd_heap
    call os_munmap
    jmp .Lvdd_done
.Lvdd_heap:
    call mem_free
.Lvdd_done:
    mov qword ptr [rbx + ViewerDialog.data], 0
    pop rbx
    ret

# void ViewerDialog_layout(ViewerDialog *this, int x, int y, int w, int h)
ViewerDialog_layout:
    push rbx
    mov rbx, rdi
    mov r9d, ecx
    sub r9d, 4
    cmp r9d, 30
    jge .Lvdl_wok
    mov r9d, ecx
.Lvdl_wok:
    mov r10d, r8d
    sub r10d, 2
    cmp r10d, 12
    jge .Lvdl_hok
    mov r10d, r8d
.Lvdl_hok:
    mov eax, ecx
    sub eax, r9d
    sar eax, 1
    add eax, esi
    mov r11d, r8d
    sub r11d, r10d
    sar r11d, 1
    add r11d, edx
    mov rdi, rbx
    mov esi, eax
    mov edx, r11d
    mov ecx, r9d
    mov r8d, r10d
    call Widget_layout
    mov eax, [rbx + Widget.h]
    sub eax, 5
    mov [rbx + ViewerDialog.vis_rows], eax
    call i18n_get
    mov rsi, [rax + LangStrings.dlg_btn_hex]
    mov rdx, [rax + LangStrings.dlg_btn_close]
    mov rdi, rbx
    call dlg_layout_right_buttons
    pop rbx
    ret

# Hex/Text toggle (button 0 / 'h'): hex keeps the byte position of the text view
ViewerDialog_on_btn0:
    xor dword ptr [rdi + ViewerDialog.hex_mode], 1
    jz .Lvb_text
    mov rax, [rdi + ViewerDialog.top_off]
    shr rax, 4
    mov [rdi + ViewerDialog.hex_row], rax
    jmp .Lvb_dirty
.Lvb_text:
    mov qword ptr [rdi + ViewerDialog.top_off], 0
    mov qword ptr [rdi + ViewerDialog.top_line], 0
.Lvb_dirty:
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    ret

# ------------------------------------------------------------------------------
# Text navigation helpers (rdi = this)
# ------------------------------------------------------------------------------

# Internal: int vw_line_down(ViewerDialog *this) -> 1 moved, 0 at last line
vw_line_down:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + ViewerDialog.data]
    test rdi, rdi
    jz .Lvld_no
    mov rax, [rbx + ViewerDialog.top_off]
    mov rsi, [rbx + ViewerDialog.data_len]
    sub rsi, rax
    jbe .Lvld_no
    add rdi, rax
    mov edx, 10
    call os_mem_find_byte
    lea rcx, [rax + 1]
    cmp rax, rsi
    jae .Lvld_no                      # no newline after the top line
    add rcx, [rbx + ViewerDialog.top_off]
    cmp rcx, [rbx + ViewerDialog.data_len]
    jae .Lvld_no                      # trailing newline: nothing below
    mov [rbx + ViewerDialog.top_off], rcx
    inc qword ptr [rbx + ViewerDialog.top_line]
    mov eax, 1
    pop rbx
    ret
.Lvld_no:
    xor eax, eax
    pop rbx
    ret

# Internal: int vw_line_up(ViewerDialog *this) -> 1 moved, 0 at first line
vw_line_up:
    mov rax, [rdi + ViewerDialog.top_off]
    test rax, rax
    jz .Lvlu_no
    mov rcx, [rdi + ViewerDialog.data]
    sub rax, 2                        # skip the newline that ends the previous line
    js .Lvlu_zero
.Lvlu_scan:
    cmp byte ptr [rcx + rax], 10
    je .Lvlu_found
    test rax, rax
    jz .Lvlu_zero
    dec rax
    jmp .Lvlu_scan
.Lvlu_found:
    inc rax
    jmp .Lvlu_set
.Lvlu_zero:
    xor eax, eax
.Lvlu_set:
    mov [rdi + ViewerDialog.top_off], rax
    dec qword ptr [rdi + ViewerDialog.top_line]
    jns .Lvlu_yes
    mov qword ptr [rdi + ViewerDialog.top_line], 0
.Lvlu_yes:
    mov eax, 1
    ret
.Lvlu_no:
    xor eax, eax
    ret

# Internal: void vw_scroll(ViewerDialog *this, int64_t delta) -- lines (text) or rows (hex)
vw_scroll:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rbx + ViewerDialog.hex_mode], 0
    jne .Lvs_hex
.Lvs_text:
    test r12, r12
    jz .Lvs_done
    js .Lvs_up
    mov rdi, rbx
    call vw_line_down
    test eax, eax
    jz .Lvs_done
    dec r12
    jmp .Lvs_text
.Lvs_up:
    mov rdi, rbx
    call vw_line_up
    test eax, eax
    jz .Lvs_done
    inc r12
    jmp .Lvs_text
.Lvs_hex:
    mov rax, [rbx + ViewerDialog.hex_row]
    add rax, r12
    jns .Lvs_hmax
    xor eax, eax
.Lvs_hmax:
    mov rcx, [rbx + ViewerDialog.data_len]
    add rcx, 15
    shr rcx, 4                        # total rows
    dec rcx
    jns .Lvs_hclamp
    xor ecx, ecx
.Lvs_hclamp:
    cmp rax, rcx
    jbe .Lvs_hset
    mov rax, rcx
.Lvs_hset:
    mov [rbx + ViewerDialog.hex_row], rax
.Lvs_done:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: void vw_home(ViewerDialog *this)
vw_home:
    xor eax, eax
    mov [rdi + ViewerDialog.top_off], rax
    mov [rdi + ViewerDialog.top_line], rax
    mov [rdi + ViewerDialog.hex_row], rax
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    ret
