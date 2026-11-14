# src/ui/git_render.s - Git branch badge (HeaderBar) & status column (FilePane)
.intel_syntax noprefix

.include "classes.inc"

.section .rodata
git_badge_pfx: .asciz " ["
git_badge_sfx: .asciz "]"

.section .text
.global fp_draw_glyph_and_git
.global hdr_draw_git_badge

.extern ScreenBuffer_set_cell_pen
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_text
.extern DirModel_entry_name
.extern git_lookup
.extern git_branch
.extern str_len
.extern str_copy
.extern str_cat

# void fp_draw_glyph_and_git(ScreenBuffer *scr, int x3, int y, uint32_t glyph,
#                            FilePane *fp, FileEntry *ent, Theme *theme, uint32_t row_bg)
# Draws file glyph at x3, then if git status exists, draws M/A/?/D at x3 - 1
fp_draw_glyph_and_git:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 16
    mov rbx, rdi              # scr
    mov r12d, esi             # x3
    mov r13d, edx             # y
    mov r14, r8               # fp
    mov r15, r9               # ent
    call ScreenBuffer_set_cell_pen

    mov rdi, [r14 + FilePane.model]
    mov rsi, r15
    call DirModel_entry_name
    test rax, rax
    jz .Lfg_done
    mov rdi, [r14 + FilePane.model]
    mov rsi, rax
    call git_lookup
    test eax, eax
    jz .Lfg_done

    mov [rsp], eax            # save status char
    mov rcx, [rsp + 64]       # Theme *theme (7th stack arg: 5*8 + 16 + 8 ret = +64)
    mov r8d, [rsp + 72]       # row_bg (8th stack arg)
    # Pick fg by status char
    mov esi, [rcx + Theme.warn_fg]     # default / 'M'
    cmp eax, 'A'
    jne .Lfg_chk_q
    mov esi, [rcx + Theme.ok_fg]
    jmp .Lfg_pen
.Lfg_chk_q:
    cmp eax, '?'
    jne .Lfg_chk_d
    mov esi, [rcx + Theme.muted]
    jmp .Lfg_pen
.Lfg_chk_d:
    cmp eax, 'D'
    jne .Lfg_pen
    mov esi, [rcx + Theme.err_fg]
.Lfg_pen:
    mov rdi, rbx
    mov edx, r8d              # row_bg
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, rbx
    mov esi, r12d
    dec esi                   # x + 2
    mov edx, r13d
    mov ecx, [rsp]
    call ScreenBuffer_set_cell_pen
.Lfg_done:
    add rsp, 16
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void hdr_draw_git_badge(HeaderBar *hdr, ScreenBuffer *scr, Theme *theme, int x, int y)
hdr_draw_git_badge:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 80
    mov rbx, rdi              # hdr
    mov r12, rsi              # scr
    mov r13, rdx              # theme
    mov r14d, ecx             # x
    mov r15d, r8d             # y

    mov rax, [rbx + HeaderBar.app]
    test rax, rax; jz .Lhgb_done
    mov rax, [rax + App.active_pane]
    test rax, rax; jz .Lhgb_done
    mov rdi, [rax + FilePane.model]
    call git_branch
    cmp byte ptr [rax], 0
    je .Lhgb_done

    push rax
    mov rdi, rsp; add rdi, 8
    lea rsi, [rip + git_badge_pfx]
    mov edx, 72
    call str_copy
    pop rsi
    mov rdi, rsp; mov edx, 72; call str_cat
    mov rdi, rsp; lea rsi, [rip + git_badge_sfx]; mov edx, 72; call str_cat

    mov rdi, r12
    mov esi, [r13 + Theme.badge_fg]
    mov edx, [r13 + Theme.badge_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, rsp; call str_len
    mov r8d, eax
    mov rdi, r12
    mov esi, r14d
    mov edx, r15d
    mov rcx, rsp
    call ScreenBuffer_draw_text
.Lhgb_done:
    add rsp, 80
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
