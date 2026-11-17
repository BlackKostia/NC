# Frozen reference oracle: the hand-written asm that src/fs/trash_info.c, trash_dirs.c and trash_undo.c replaced (tests/test_c_trash.py diffs against it)
# src/fs/trash_undo.s - freedesktop.org XDG Trash and 16-deep Undo stack — trash undo ops (split from trash_undo.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.equ UNDO_MAX,    16
.equ UNDO_NONE,   0
.equ UNDO_RENAME, 1
.equ UNDO_MOVE,   2
.equ UNDO_TRASH,  3
.struct 0
UndoSlot.kind:  .space 4
UndoSlot.pad:   .space 4
UndoSlot.orig:  .space PATH_MAX
UndoSlot.cur:   .space PATH_MAX
UndoSlot.info:  .space PATH_MAX
UndoSlot._size:

.extern str_len
.extern str_copy
.extern str_cat
.extern str_starts_with
.extern path_basename
.extern path_join
.extern u64_to_dec
.extern os_statat
.extern sys_write_all
.extern fs_copy_recursive
.extern fs_delete_recursive

.section .bss

.align 8
g_undo_slots:   .space UNDO_MAX * UndoSlot._size
g_undo_top:     .space 4

.section .text
.global trash_move_file
.global undo_push
.global undo_pop_and_apply

# int tmf_copy_move(const char *src, const char *dst) -> 0, or -errno (edx = 1: dst complete, src left)
# Cross-filesystem move onto a name that must still be free. Copy errors drop the partial copy and
# leave the original untouched; special files (FIFO...) are refused by the copy engine.
tmf_copy_move:
    push rbx; push r12; push r13
    sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    jns .Ltcm_exists
    mov rdi, rbx
    mov rsi, r12
    call fs_copy_recursive
    test eax, eax
    js .Ltcm_failed
    mov r13d, 1
    mov rdi, rbx
    call fs_delete_recursive
    jmp .Ltcm_ret
.Ltcm_exists:
    mov eax, -EEXIST
    jmp .Ltcm_ret
.Ltcm_failed:
    mov ebx, eax
    mov rdi, r12
    call fs_delete_recursive
    mov eax, ebx
.Ltcm_ret:
    mov edx, r13d
    add rsp, FileStat._size + 8
    pop r13; pop r12; pop rbx
    ret

# int trash_move_file(const char *src_path, const char **envp, char *out_trash_path, char *out_info_path)
trash_move_file:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, PATH_MAX + 8
    mov rbx, rdi              # src_path
    mov r12, rsi              # envp
    mov r13, rdx              # out_trash_path
    mov r14, rcx              # out_info_path

    mov rdi, r12
    mov rsi, rsp
    mov edx, PATH_MAX
    call tu_get_data_home

    mov rdi, rsp
    call tu_mkdir_p_base

    mov rdi, rbx
    call path_basename
    mov rdi, rsp
    mov rsi, rax
    mov rdx, r13
    mov rcx, r14
    call tu_pick_unique
    test eax, eax
    js .Ltmf_ret              # no free trash name: nothing was touched

    mov rdi, r14
    mov rsi, rbx
    call tu_write_info
    test eax, eax
    js .Ltmf_ret

    mov rdi, rbx
    mov rsi, r13
    call fs_rename_noreplace  # never replaces an item that is already in the trash
    test rax, rax
    jns .Ltmf_ok
    cmp eax, -EXDEV
    jne .Ltmf_unlink_info
    mov rdi, rbx              # other filesystem: copy into the trash, then remove the original
    mov rsi, r13
    call tmf_copy_move
    test eax, eax
    jns .Ltmf_ok
    test edx, edx
    jnz .Ltmf_ret             # trash copy is complete, original not removable: keep the info file
    movsxd rax, eax
    jmp .Ltmf_unlink_info
.Ltmf_ok:
    xor eax, eax
    jmp .Ltmf_ret
.Ltmf_unlink_info:
    push rax
    mov edi, AT_FDCWD
    mov rsi, r14
    xor edx, edx
    OS_UNLINKAT
    pop rax
.Ltmf_ret:
    add rsp, PATH_MAX + 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void undo_push(int kind, const char *orig_path, const char *cur_path, const char *info_path)
undo_push:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx

    mov eax, [rip + g_undo_top]
    cmp eax, UNDO_MAX
    jb .Lup_slot
    # Shift slots down by 1
    lea rdi, [rip + g_undo_slots]
    lea rsi, [rdi + UndoSlot._size]
    mov rcx, (UNDO_MAX - 1) * UndoSlot._size
.Lup_sh:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec rcx
    jnz .Lup_sh
    mov eax, UNDO_MAX - 1
    mov [rip + g_undo_top], eax
.Lup_slot:
    imul rbx, rax, UndoSlot._size
    lea r8, [rip + g_undo_slots]
    add rbx, r8
    inc eax
    mov [rip + g_undo_top], eax

    mov [rbx + UndoSlot.kind], r12d
    lea rdi, [rbx + UndoSlot.orig]
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy
    lea rdi, [rbx + UndoSlot.cur]
    mov rsi, r14
    mov edx, PATH_MAX
    call str_copy
    mov byte ptr [rbx + UndoSlot.info], 0
    test r15, r15
    jz .Lup_done
    lea rdi, [rbx + UndoSlot.info]
    mov rsi, r15
    mov edx, PATH_MAX
    call str_copy
.Lup_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int undo_pop_and_apply(void) -> 1=undone, 0=empty, <0=-errno
undo_pop_and_apply:
    push rbx
    mov eax, [rip + g_undo_top]
    test eax, eax
    jle .Lupa_empty
    dec eax
    imul rbx, rax, UndoSlot._size
    lea rcx, [rip + g_undo_slots]
    add rbx, rcx

    lea rdi, [rbx + UndoSlot.cur]
    lea rsi, [rbx + UndoSlot.orig]
    call fs_rename_noreplace  # never replaces a file that appeared at the original place meanwhile
    test rax, rax
    jns .Lupa_chk_trash
    cmp eax, -EEXIST
    je .Lupa_conflict
    cmp eax, -EXDEV
    jne .Lupa_drop
    lea rdi, [rbx + UndoSlot.cur]
    lea rsi, [rbx + UndoSlot.orig]
    call tmf_copy_move        # other filesystem: copy back onto a free name, then remove the trash copy
    test eax, eax
    jns .Lupa_chk_trash
    cmp eax, -EEXIST
    je .Lupa_conflict
.Lupa_drop:
    movsxd rax, eax
    dec dword ptr [rip + g_undo_top]      # unrecoverable failure: the entry is dropped
    pop rbx
    ret
.Lupa_conflict:
    mov rax, -EEXIST          # something is in the way: keep the entry so Ctrl+Z can be retried
    pop rbx
    ret
.Lupa_chk_trash:
    dec dword ptr [rip + g_undo_top]
    cmp dword ptr [rbx + UndoSlot.kind], UNDO_TRASH
    jne .Lupa_ok
    cmp byte ptr [rbx + UndoSlot.info], 0
    je .Lupa_ok
    mov edi, AT_FDCWD
    lea rsi, [rbx + UndoSlot.info]
    xor edx, edx
    OS_UNLINKAT
.Lupa_ok:
    mov eax, 1
    pop rbx
    ret
.Lupa_empty:
    xor eax, eax
    pop rbx
    ret
