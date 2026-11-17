# Frozen reference oracle: the hand-written asm that src/fs/nav_state.c and nav_persist.c replaced (tests/test_c_nav_state.py diffs against it)
# Duop Navigation State: Per-tab History, Bookmarks (Hotlist) & Frecency (z) — history (split from nav_state.s)

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

.section .text
.global nav_hist_push
.global nav_hist_back
.global nav_hist_fwd

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
    call nav_hist_push__skip_equal_current_history
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
    call nav_hist_push__part2
.Lnhp_append:
    call nav_hist_push__drop_oldest_entry_shift
.Lnhp_done:
    pop r13
    pop r12
    pop rbx
.Lnhp_ret:
    ret

# nav_hist_push step: Skip if equal to current history head (runs on the caller's frame)
nav_hist_push__skip_equal_current_history:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi

    # Skip if equal to current history head
    mov eax, [rbx + TAB_HIST_LEN]
    test eax, eax
.Lnav_hist_push__skip_equal_current_history_ret:
    lea rsp, [rsp + 8]
    ret

# nav_hist_push step (runs on the caller's frame)
nav_hist_push__part2:
    lea rsp, [rsp - 8]
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

.Lnav_hist_push__part2_ret:
    lea rsp, [rsp + 8]
    ret

# nav_hist_push step: Drop oldest entry and shift left (runs on the caller's frame)
nav_hist_push__drop_oldest_entry_shift:
    lea rsp, [rsp - 8]
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
    jz .Lnav_hist_push__drop_oldest_entry_shift_ret
    mov ecx, [rbx + TAB_HIST_LEN]
    mov [rbx + TAB_HIST_PTRS + rcx*8], rax
    mov [rbx + TAB_HIST_POS], ecx
    inc ecx
    mov [rbx + TAB_HIST_LEN], ecx

.Lnav_hist_push__drop_oldest_entry_shift_ret:
    lea rsp, [rsp + 8]
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
