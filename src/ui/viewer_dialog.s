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

.global ViewerDialog_vtbl
ViewerDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ViewerDialog, Dialog_vtbl, ViewerDialog._size, ViewerDialog_dtor, ViewerDialog_layout, ViewerDialog_render, ViewerDialog_on_key, ViewerDialog_on_mouse, Widget_on_focus, Widget_hit_test, ViewerDialog_on_btn0, Dialog_on_cancel

.section .text
.global ViewerDialog_new
.global ViewerDialog_dtor
.global ViewerDialog_layout
.global ViewerDialog_render
.global ViewerDialog_on_key
.global ViewerDialog_on_mouse
.global ViewerDialog_on_btn0

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
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lvdn_close
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Lvdn_close
    mov rsi, [rsp + FileStat.size]
    test rsi, rsi
    jle .Lvdn_close
    mov edi, r14d
    call os_mmap_file_ro
    test rax, rax
    jz .Lvdn_close
    mov [rbx + ViewerDialog.data], rax
    mov rax, [rsp + FileStat.size]
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
    # Binary when a NUL byte occurs in the first 512 bytes -> start in Hex mode
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
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call ViewerDialog_layout
    mov rax, rbx
.Lvdn_ret:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rbx
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

# Internal: void vw_end(ViewerDialog *this) -- last page; counts lines once (SIMD)
vw_end:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov rcx, [rbx + ViewerDialog.data_len]
    cmp dword ptr [rbx + ViewerDialog.hex_mode], 0
    je .Lve_text
    add rcx, 15
    shr rcx, 4
    movsxd rax, dword ptr [rbx + ViewerDialog.vis_rows]
    sub rcx, rax
    jns .Lve_hset
    xor ecx, ecx
.Lve_hset:
    mov [rbx + ViewerDialog.hex_row], rcx
    jmp .Lve_done
.Lve_text:
    mov rdi, [rbx + ViewerDialog.data]
    test rdi, rdi
    jz .Lve_done
    test rcx, rcx
    jz .Lve_done
    cmp qword ptr [rbx + ViewerDialog.total_lines], 0
    jge .Lve_have_total
    mov rsi, rcx
    mov edx, 10
    call os_mem_count_byte
    mov rcx, [rbx + ViewerDialog.data_len]
    mov rdx, [rbx + ViewerDialog.data]
    cmp byte ptr [rdx + rcx - 1], 10
    je .Lve_store_total
    inc rax                           # unterminated last line
.Lve_store_total:
    mov [rbx + ViewerDialog.total_lines], rax
.Lve_have_total:
    # Start of the last line
    mov rdx, [rbx + ViewerDialog.data]
    mov rcx, [rbx + ViewerDialog.data_len]
    lea rax, [rcx - 1]
    cmp byte ptr [rdx + rax], 10
    jne .Lve_back
    dec rax                           # ignore the final terminator
.Lve_back:
    test rax, rax
    js .Lve_first
    cmp byte ptr [rdx + rax], 10
    je .Lve_found
    dec rax
    jmp .Lve_back
.Lve_found:
    inc rax
    jmp .Lve_set
.Lve_first:
    xor eax, eax
.Lve_set:
    mov [rbx + ViewerDialog.top_off], rax
    mov rax, [rbx + ViewerDialog.total_lines]
    dec rax
    jns .Lve_line
    xor eax, eax
.Lve_line:
    mov [rbx + ViewerDialog.top_line], rax
    movsxd r12, dword ptr [rbx + ViewerDialog.vis_rows]
    dec r12
.Lve_up:
    test r12, r12
    jle .Lve_done
    mov rdi, rbx
    call vw_line_up
    test eax, eax
    jz .Lve_done
    dec r12
    jmp .Lve_up
.Lve_done:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    add rsp, 8
    pop r12
    pop rbx
    ret

# void ViewerDialog_render(ViewerDialog *this, ScreenBuffer *scr, Theme *theme)
ViewerDialog_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 344                      # [8..263]=line, [264..295]=num, [296]=rows, [300]=row,
                                      # [304]=numw, [312]=line_no, [320]=cursor off
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_hex]
    mov r8,  [rax + LangStrings.dlg_btn_close]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.dir_fg]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    inc edx
    lea rcx, [rbx + ViewerDialog.path]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.dlg_vw_hint]
    movsx r8d, word ptr [rbx + Dialog.btns + HitZone.x1]
    mov eax, [rbx + Widget.x]
    add eax, 3
    sub r8d, eax
    cmp r8d, 0
    jle .Lvr_skip_hint
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    call ScreenBuffer_draw_text
.Lvr_skip_hint:

    mov eax, [rbx + Widget.h]
    sub eax, 5
    mov [rbx + ViewerDialog.vis_rows], eax
    cmp eax, 1
    jl .Lvr_done
    mov [rsp + 296], eax
    cmp qword ptr [rbx + ViewerDialog.data], 0
    je .Lvr_done
    cmp dword ptr [rbx + ViewerDialog.hex_mode], 0
    jne .Lvr_hex

    # ---- Text mode: number column width from the last visible line number ----
    mov rdi, [rbx + ViewerDialog.top_line]
    movsxd rax, dword ptr [rsp + 296]
    add rdi, rax
    lea rsi, [rsp + 264]
    call u64_to_dec
    cmp eax, 5
    jge .Lvr_numw
    mov eax, 5
.Lvr_numw:
    inc eax
    mov [rsp + 304], eax
    mov rax, [rbx + ViewerDialog.top_line]
    mov [rsp + 312], rax
    mov rax, [rbx + ViewerDialog.top_off]
    mov [rsp + 320], rax
    mov dword ptr [rsp + 300], 0
.Lvr_tloop:
    mov eax, [rsp + 300]
    cmp eax, [rsp + 296]
    jge .Lvr_done
    mov r14, [rsp + 320]
    cmp r14, [rbx + ViewerDialog.data_len]
    jae .Lvr_done

    # line number
    mov rdi, [rsp + 312]
    inc rdi
    lea rsi, [rsp + 264]
    call u64_to_dec
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, [rsp + 300]
    lea rcx, [rsp + 264]
    mov r8d, [rsp + 304]
    call ScreenBuffer_draw_text_pad

    # line end via SIMD newline search
    mov rdi, [rbx + ViewerDialog.data]
    add rdi, r14
    mov rsi, [rbx + ViewerDialog.data_len]
    sub rsi, r14
    mov edx, 10
    call os_mem_find_byte
    mov r15, rax                      # line length
    lea rax, [r14 + r15 + 1]
    mov [rsp + 320], rax              # next line offset

    # copy (tabs -> 2 spaces, CR dropped, capped)
    mov rbp, [rbx + ViewerDialog.data]
    add rbp, r14
    xor ecx, ecx                      # src index
    xor edx, edx                      # dst index
.Lvr_copy:
    cmp rcx, r15
    jae .Lvr_copied
    cmp edx, VW_LINE_MAX
    jae .Lvr_copied
    mov al, [rbp + rcx]
    inc rcx
    cmp al, 13
    je .Lvr_copy
    cmp al, 9
    jne .Lvr_ch
    mov byte ptr [rsp + 8 + rdx], ' '
    mov byte ptr [rsp + 9 + rdx], ' '
    add edx, 2
    jmp .Lvr_copy
.Lvr_ch:
    test al, al
    jnz .Lvr_put
    mov al, '.'
.Lvr_put:
    mov [rsp + 8 + rdx], al
    inc edx
    jmp .Lvr_copy
.Lvr_copied:
    mov byte ptr [rsp + 8 + rdx], 0
    mov eax, [r13 + Theme.dialog_bg]
    push rax
    push r13
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    add esi, [rsp + 304 + 16]
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, [rsp + 300 + 16]
    lea rcx, [rsp + 8 + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 5
    sub r8d, [rsp + 304 + 16]
    lea r9, [rbx + ViewerDialog.path]
    call syntax_draw_line
    add rsp, 16
    inc dword ptr [rsp + 300]
    inc qword ptr [rsp + 312]
    jmp .Lvr_tloop

    # ---- Hex mode: "OFFSET: XX XX ... |ascii|" ----
.Lvr_hex:
    mov rax, [rbx + ViewerDialog.hex_row]
    shl rax, 4
    mov [rsp + 320], rax
    mov dword ptr [rsp + 300], 0
.Lvr_hloop:
    mov eax, [rsp + 300]
    cmp eax, [rsp + 296]
    jge .Lvr_done
    mov r14, [rsp + 320]
    cmp r14, [rbx + ViewerDialog.data_len]
    jae .Lvr_done
    mov rdi, r14
    lea rsi, [rsp + 8]
    mov edx, 8
    call u64_to_hex
    mov r15d, eax                     # offset digits
    mov byte ptr [rsp + 8 + r15], ':'
    mov byte ptr [rsp + 9 + r15], ' '
    lea r9d, [r15d + 2]               # hex write pos
    lea r10d, [r15d + 2 + 49]         # ascii write pos
    mov byte ptr [rsp + 8 + r10 - 1], '|'
    mov rbp, [rbx + ViewerDialog.data]
    xor ecx, ecx
.Lvr_hb:
    cmp ecx, 16
    jge .Lvr_hend
    lea rax, [r14 + rcx]
    cmp rax, [rbx + ViewerDialog.data_len]
    jae .Lvr_hpad
    movzx edi, byte ptr [rbp + rax]
    mov eax, edi
    shr eax, 4
    lea rdx, [rip + vw_hex]
    mov al, [rdx + rax]
    mov [rsp + 8 + r9], al
    mov eax, edi
    and eax, 15
    mov al, [rdx + rax]
    mov [rsp + 9 + r9], al
    mov byte ptr [rsp + 10 + r9], ' '
    cmp dil, 0x20
    jb .Lvr_dot
    cmp dil, 0x7E
    jbe .Lvr_asc
.Lvr_dot:
    mov dil, '.'
.Lvr_asc:
    mov [rsp + 8 + r10], dil
    jmp .Lvr_hnext
.Lvr_hpad:
    mov byte ptr [rsp + 8 + r9], ' '
    mov byte ptr [rsp + 9 + r9], ' '
    mov byte ptr [rsp + 10 + r9], ' '
    mov byte ptr [rsp + 8 + r10], ' '
.Lvr_hnext:
    add r9d, 3
    inc r10d
    inc ecx
    jmp .Lvr_hb
.Lvr_hend:
    mov byte ptr [rsp + 8 + r9], ' '
    mov byte ptr [rsp + 8 + r10], '|'
    mov byte ptr [rsp + 9 + r10], 0
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, [rsp + 300]
    lea rcx, [rsp + 8]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text
    add qword ptr [rsp + 320], 16
    inc dword ptr [rsp + 300]
    jmp .Lvr_hloop

.Lvr_done:
    add rsp, 344
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int ViewerDialog_on_key(ViewerDialog *this, Event *evt)
ViewerDialog_on_key:
    push rbx
    mov rbx, rdi
    push rsi
    call hex_edit_on_key
    pop rsi
    test eax, eax
    jnz .Lvk_ret
    mov eax, [rsi + Event.key]
    cmp eax, KEY_ESC;   je .Lvk_close
    cmp eax, 'q';       je .Lvk_close; cmp eax, 'Q'; je .Lvk_close
    cmp eax, KEY_F3;    je .Lvk_close; cmp eax, KEY_F10; je .Lvk_close
    cmp eax, 'h';       je .Lvk_hex;   cmp eax, 'H'; je .Lvk_hex
    cmp eax, KEY_UP;    je .Lvk_up;    cmp eax, 'k'; je .Lvk_up
    cmp eax, KEY_DOWN;  je .Lvk_dn;    cmp eax, 'j'; je .Lvk_dn
    cmp eax, KEY_PGUP;  je .Lvk_pgup
    cmp eax, KEY_PGDN;  je .Lvk_pgdn;  cmp eax, ' '; je .Lvk_pgdn
    cmp eax, KEY_HOME;  je .Lvk_home;  cmp eax, KEY_END; je .Lvk_end
    jmp .Lvk_ret
.Lvk_close:
    mov rdi, rbx
    VCALL DialogVtbl.on_cancel
    jmp .Lvk_ret
.Lvk_hex:
    mov rdi, rbx
    call ViewerDialog_on_btn0
    jmp .Lvk_ret
.Lvk_up:
    mov rsi, -1
    jmp .Lvk_scroll
.Lvk_dn:
    mov esi, 1
    jmp .Lvk_scroll
.Lvk_pgup:
    movsxd rsi, dword ptr [rbx + ViewerDialog.vis_rows]
    dec rsi
    neg rsi
    jmp .Lvk_scroll
.Lvk_pgdn:
    movsxd rsi, dword ptr [rbx + ViewerDialog.vis_rows]
    dec rsi
.Lvk_scroll:
    mov rdi, rbx
    call vw_scroll
    jmp .Lvk_ret
.Lvk_home:
    mov rdi, rbx
    call vw_home
    jmp .Lvk_ret
.Lvk_end:
    mov rdi, rbx
    call vw_end
.Lvk_ret:
    mov eax, 1
    pop rbx
    ret

# int ViewerDialog_on_mouse(ViewerDialog *this, Event *evt)
ViewerDialog_on_mouse:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne Dialog_on_mouse
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.mouse_btn]
    mov esi, 3
    cmp eax, MOUSE_WHEEL_UP
    jne .Lvm_go
    mov rsi, -3
.Lvm_go:
    mov rdi, rbx
    call vw_scroll
    mov eax, 1
    pop rbx
    ret

.section .rodata
vw_hex: .ascii "0123456789abcdef"
