# src/fs/trash_undo.s - freedesktop.org XDG Trash and 16-deep Undo stack
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

.section .rodata
str_env_xdg:    .asciz "XDG_DATA_HOME="
str_env_home:   .asciz "HOME="
str_local_shr:  .asciz "/.local/share"
str_trash_dir:  .asciz "/Trash"
str_files_dir:  .asciz "/Trash/files"
str_info_dir:   .asciz "/Trash/info"
str_trash_hdr:  .asciz "[Trash Info]\nPath="
str_trash_dt:   .asciz "\nDeletionDate=2026-11-14T00:00:00\n"
str_trash_ext:  .asciz ".trashinfo"
str_tmp_fb:     .asciz "/tmp"

.section .bss
.align 8
g_undo_slots:   .space UNDO_MAX * UndoSlot._size
g_undo_top:     .space 4

.section .text
.global trash_move_file
.global undo_push
.global undo_pop_and_apply

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

# Helper: const char *tu_find_env(const char **envp, const char *pfx, size_t pfx_len)
tu_find_env:
    test rdi, rdi
    jz .Ltfe_none
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.Ltfe_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Ltfe_miss
    mov rsi, r12
    call str_starts_with
    test eax, eax
    jnz .Ltfe_hit
    add rbx, 8
    jmp .Ltfe_loop
.Ltfe_hit:
    mov rax, [rbx]
    add rax, r13
    cmp byte ptr [rax], 0
    je .Ltfe_miss
    pop r13
    pop r12
    pop rbx
    ret
.Ltfe_miss:
    pop r13
    pop r12
    pop rbx
.Ltfe_none:
    xor eax, eax
    ret

# Helper: void tu_get_data_home(const char **envp, char *dst, size_t cap)
tu_get_data_home:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    lea rsi, [rip + str_env_xdg]
    mov edx, 14
    call tu_find_env
    test rax, rax
    jz .Ltgdh_home
    mov rdi, r12
    mov rsi, rax
    mov rdx, r13
    call str_copy
    jmp .Ltgdh_done
.Ltgdh_home:
    mov rdi, rbx
    lea rsi, [rip + str_env_home]
    mov edx, 5
    call tu_find_env
    test rax, rax
    jz .Ltgdh_fb
    mov rdi, r12
    mov rsi, rax
    mov rdx, r13
    call str_copy
    mov rdi, r12
    lea rsi, [rip + str_local_shr]
    mov rdx, r13
    call str_cat
    jmp .Ltgdh_done
.Ltgdh_fb:
    mov rdi, r12
    lea rsi, [rip + str_tmp_fb]
    mov rdx, r13
    call str_copy
.Ltgdh_done:
    pop r13
    pop r12
    pop rbx
    ret

# Helper: void tu_mkdir_p_base(const char *data_home)
tu_mkdir_p_base:
    push rbx
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    # Ensure data_home itself exists if XDG_DATA_HOME was custom
    mov edi, AT_FDCWD
    mov rsi, rbx
    mov edx, 0700
    OS_MKDIRAT

    mov rdi, rsp
    mov rsi, rbx
    mov edx, PATH_MAX
    call str_copy
    mov rdi, rsp
    lea rsi, [rip + str_trash_dir]
    mov edx, PATH_MAX
    call str_cat
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, 0700
    OS_MKDIRAT

    mov rdi, rsp
    mov rsi, rbx
    mov edx, PATH_MAX
    call str_copy
    mov rdi, rsp
    lea rsi, [rip + str_files_dir]
    mov edx, PATH_MAX
    call str_cat
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, 0700
    OS_MKDIRAT

    mov rdi, rsp
    mov rsi, rbx
    mov edx, PATH_MAX
    call str_copy
    mov rdi, rsp
    lea rsi, [rip + str_info_dir]
    mov edx, PATH_MAX
    call str_cat
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, 0700
    OS_MKDIRAT

    add rsp, PATH_MAX + 8
    pop rbx
    ret

# Helper: int tu_write_info(const char *info_path, const char *orig_path)
tu_write_info:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0600
    OS_OPENAT
    test rax, rax
    js .Ltwi_err
    mov ebx, eax

    mov edi, ebx
    lea rsi, [rip + str_trash_hdr]
    mov edx, 18
    call sys_write_all

    mov rdi, r12
    call str_len
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call sys_write_all

    mov edi, ebx
    lea rsi, [rip + str_trash_dt]
    mov edx, 35
    call sys_write_all

    mov edi, ebx
    OS_CLOSE
    xor eax, eax
.Ltwi_err:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Helper: void tu_pick_unique(const char *data_home, const char *base, char *out_files, char *out_info)
tu_pick_unique:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, FileStat._size + 40
    # [rsp+0..31] = suffix buf, [rsp+32..] = FileStat
    mov rbx, rdi              # data_home
    mov r12, rsi              # base
    mov r13, rdx              # out_files
    mov r14, rcx              # out_info
    mov ebp, 1                # suffix counter

.Ltpu_try:
    mov rdi, r13
    mov rsi, rbx
    mov edx, PATH_MAX
    call str_copy
    mov rdi, r13
    lea rsi, [rip + str_files_dir]
    mov edx, PATH_MAX
    call str_cat
    mov rdi, r13
    mov rsi, r13
    mov rdx, r12
    mov ecx, PATH_MAX
    call path_join

    mov rdi, r14
    mov rsi, rbx
    mov edx, PATH_MAX
    call str_copy
    mov rdi, r14
    lea rsi, [rip + str_info_dir]
    mov edx, PATH_MAX
    call str_cat
    mov rdi, r14
    mov rsi, r14
    mov rdx, r12
    mov ecx, PATH_MAX
    call path_join

    cmp ebp, 1
    je .Ltpu_chk
    mov byte ptr [rsp], '.'
    mov edi, ebp
    lea rsi, [rsp + 1]
    call u64_to_dec
    mov rdi, r13
    mov rsi, rsp
    mov edx, PATH_MAX
    call str_cat
    mov rdi, r14
    mov rsi, rsp
    mov edx, PATH_MAX
    call str_cat

.Ltpu_chk:
    mov rdi, r14
    lea rsi, [rip + str_trash_ext]
    mov edx, PATH_MAX
    call str_cat

    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 32]
    mov ecx, AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax
    js .Ltpu_ok
    inc ebp
    cmp ebp, 999
    jb .Ltpu_try
.Ltpu_ok:
    add rsp, FileStat._size + 40
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
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

    mov rdi, r14
    mov rsi, rbx
    call tu_write_info
    test eax, eax
    js .Ltmf_ret

    mov edi, AT_FDCWD
    mov rsi, rbx
    mov edx, AT_FDCWD
    mov r10, r13
    OS_RENAMEAT
    test rax, rax
    jns .Ltmf_ok
    cmp eax, -EXDEV
    jne .Ltmf_unlink_info
    mov rdi, rbx
    mov rsi, r13
    call fs_copy_recursive
    test eax, eax
    js .Ltmf_unlink_info
    mov rdi, rbx
    call fs_delete_recursive
    test eax, eax
    js .Ltmf_ret
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
    mov [rip + g_undo_top], eax
    imul rbx, rax, UndoSlot._size
    lea rcx, [rip + g_undo_slots]
    add rbx, rcx

    mov edi, AT_FDCWD
    lea rsi, [rbx + UndoSlot.cur]
    mov edx, AT_FDCWD
    lea r10, [rbx + UndoSlot.orig]
    OS_RENAMEAT
    test rax, rax
    jns .Lupa_chk_trash
    cmp eax, -EXDEV
    jne .Lupa_ret
    lea rdi, [rbx + UndoSlot.cur]
    lea rsi, [rbx + UndoSlot.orig]
    call fs_copy_recursive
    test eax, eax
    js .Lupa_ret
    lea rdi, [rbx + UndoSlot.cur]
    call fs_delete_recursive
    test eax, eax
    js .Lupa_ret
.Lupa_chk_trash:
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
.Lupa_ret:
    pop rbx
    ret
