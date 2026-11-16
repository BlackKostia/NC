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

.section .rodata
str_env_xdg:    .asciz "XDG_DATA_HOME="
str_env_home:   .asciz "HOME="
str_local_shr:  .asciz "/.local/share"
str_trash_dir:  .asciz "/Trash"
str_files_dir:  .asciz "/Trash/files"
str_info_dir:   .asciz "/Trash/info"
str_trash_ext:  .asciz ".trashinfo"
str_tmp_fb:     .asciz "/tmp"

.section .text
.global tu_get_data_home
.global tu_mkdir_p_base
.global tu_pick_unique

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

# Helper: void tu_pick_unique(const char *data_home, const char *base, char *out_files, char *out_info)
tu_pick_unique:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, FileStat._size + 40
    # [rsp+0..31] = suffix buf, [rsp+32..] = FileStat
    call tu_pick_unique__data_home
.Ltpu_try:
    call tu_pick_unique__path_join
    call tu_pick_unique__os_statat
    js .Ltpu_ok
    inc ebp
    cmp ebp, 999
    jb .Ltpu_try
    mov eax, -EEXIST                  # every candidate name is taken: refuse instead of overwriting
    jmp .Ltpu_ret
.Ltpu_ok:
    xor eax, eax
.Ltpu_ret:
    add rsp, FileStat._size + 40
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# tu_pick_unique step: data_home (runs on the caller's frame)
tu_pick_unique__data_home:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # data_home
    mov r12, rsi              # base
    mov r13, rdx              # out_files
    mov r14, rcx              # out_info
    mov ebp, 1                # suffix counter

.Ltu_pick_unique__data_home_ret:
    lea rsp, [rsp + 8]
    ret

# tu_pick_unique step: path_join (runs on the caller's frame)
tu_pick_unique__path_join:
    lea rsp, [rsp - 8]
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
    mov byte ptr [rsp + 16], '.'
    mov edi, ebp
    lea rsi, [rsp + 1 + 16]
    call u64_to_dec
    mov rdi, r13
    lea rsi, [rsp + 16]
    mov edx, PATH_MAX
    call str_cat
    mov rdi, r14
    lea rsi, [rsp + 16]
    mov edx, PATH_MAX
    call str_cat

.Ltpu_chk:
    mov rdi, r14
    lea rsi, [rip + str_trash_ext]
    mov edx, PATH_MAX
    call str_cat

.Ltu_pick_unique__path_join_ret:
    lea rsp, [rsp + 8]
    ret

# tu_pick_unique step: os_statat (runs on the caller's frame)
tu_pick_unique__os_statat:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 32 + 16]
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
    call os_statat
    test eax, eax
.Ltu_pick_unique__os_statat_ret:
    lea rsp, [rsp + 8]
    ret
