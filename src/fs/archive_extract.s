# src/fs/archive_vfs.s - Virtual File System for .tar, .tar.gz, .zip archives — archive extract (split from archive_vfs.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ ARC_MAX_FILE,   4194304   # 4 MiB max archive file read
.equ ARC_MAX_ENTRIES, 1024
.equ AENT_SIZE,      288
.equ ACTX_SUB,       32
.equ ACTX_ORIG,      32 + PATH_MAX
.equ ACTX_FILE,      32 + PATH_MAX * 2
.equ ACTX_SIZE,      32 + PATH_MAX * 3
.extern DirModel_cancel_load
.extern DirModel_entry_name
.extern DirModel_find_by_name
.extern DirModel_sort
.extern DirModel_chdir
.extern DirModel_apply_filter
.extern ds_append_entry
.extern fs_read_file_head
.extern inflate_raw
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern path_basename
.extern str_len
.extern str_copy
.extern str_cat
.extern str_cmp
.extern str_casecmp
.extern str_starts_with
.extern path_join
.extern path_basename

.section .rodata
arc_tmp_path:  .asciz "/tmp/duop_arc_view.tmp"

.section .text
.global arc_enter_model
.global arc_extract_entry

# int arc_enter_model(DirModel *m, const FileEntry *ent) -> 1 if handled, 2 if '..' nav_up, 0 otherwise
arc_enter_model:
    push rbx; push r12; push r13; push r14; sub rsp, PATH_MAX + 16
    mov r13, rdi; mov r14, rsi
    test r14, r14; jz .Lahe_no
    call DirModel_entry_name
    cmp dword ptr [r13 + DirModel.virtual_mode], 2
    je .Lahe_in_arc
    test dword ptr [r14 + FileEntry.flags], FE_IS_DIR; jnz .Lahe_no
    mov r14, rax
    mov rdi, r14; call arc_is_archive
    test eax, eax; jz .Lahe_no
    mov [rsp + PATH_MAX], eax
    mov rdi, rsp; lea rsi, [r13 + DirModel.path]; mov rdx, r14; mov ecx, PATH_MAX
    call path_join
    mov rdi, r13; call arc_free_ctx
    mov edi, ACTX_SIZE; call mem_alloc; test rax, rax; jz .Lahe_no
    mov r14, rax
    mov rdi, r14; mov esi, ACTX_SIZE; call mem_zero
    mov eax, [rsp + PATH_MAX]; mov [r14], eax
    mov edi, ARC_MAX_ENTRIES * AENT_SIZE; call mem_alloc; mov [r14 + 24], rax
    mov edi, ARC_MAX_FILE; call mem_alloc; mov [r14 + 8], rax
    test rax, rax; jz .Lahe_no
    mov rdi, rsp; mov rsi, rax; mov edx, ARC_MAX_FILE; lea rcx, [r14 + 16]
    call fs_read_file_head
    test rax, rax; js .Lahe_no
    lea rdi, [r14 + ACTX_ORIG]; lea rsi, [r13 + DirModel.path]; mov edx, PATH_MAX; call str_copy
    lea rdi, [r14 + ACTX_FILE]; mov rsi, rsp; mov edx, PATH_MAX; call str_copy
    cmp dword ptr [r14], 2; jne .Lahe_p
    mov rdi, [r14 + 8]; mov rsi, [r14 + 16]; lea rdx, [rsp + PATH_MAX + 8]
    call arc_ungzip
    test rax, rax; jz .Lahe_no
    push rax; mov rdi, [r14 + 8]; call mem_free; pop rax
    mov [r14 + 8], rax; mov rax, [rsp + PATH_MAX + 8]; mov [r14 + 16], rax
.Lahe_p:
    mov [r13 + DirModel.arc_ctx], rbx
    mov [r13 + DirModel.arc_ctx], r14
    mov rdi, r14
    cmp dword ptr [r14], 3; je .Lahe_pz
    call arc_parse_tar; jmp .Lahe_pop
.Lahe_pz:
    call arc_parse_zip
.Lahe_pop:
    mov rdi, r13; call arc_populate
    mov eax, 1; jmp .Lahe_ret
.Lahe_in_arc:
    test dword ptr [r14 + FileEntry.flags], FE_IS_PARENT; jz .Lahe_sub
    mov eax, 2; jmp .Lahe_ret
.Lahe_sub:
    test dword ptr [r14 + FileEntry.flags], FE_IS_DIR; jz .Lahe_no
    mov rcx, [r13 + DirModel.arc_ctx]
    lea rdi, [rcx + ACTX_SUB]; mov rsi, rax; mov edx, PATH_MAX; call str_cat
    mov rcx, [r13 + DirModel.arc_ctx]
    lea rdi, [rcx + ACTX_SUB]; call str_len
    mov byte ptr [rcx + ACTX_SUB + rax], '/'; mov byte ptr [rcx + ACTX_SUB + rax + 1], 0
    mov rdi, r13; call arc_populate
    mov eax, 1; jmp .Lahe_ret
.Lahe_no:
    xor eax, eax
.Lahe_ret:
    add rsp, PATH_MAX + 16; pop r14; pop r13; pop r12; pop rbx; ret

# int arc_extract_entry(DirModel *m, const FileEntry *ent, char *out_tmp_path) -> 0 on ok, -1 on err
arc_extract_entry:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX
    mov r13, rdi; mov rax, rsi; mov r12, rdx
    cmp dword ptr [r13 + DirModel.virtual_mode], 2; jne .Laes_err
    test rax, rax; jz .Laes_err
    test dword ptr [rax + FileEntry.flags], FE_IS_DIR; jnz .Laes_err
    mov rdi, r13; mov rsi, rax; call DirModel_entry_name
    mov r14, [r13 + DirModel.arc_ctx]
    push rax
    mov rdi, rsp; add rdi, 8; lea rsi, [r14 + ACTX_SUB]; mov edx, PATH_MAX; call str_copy
    pop rsi
    mov rdi, rsp; mov edx, PATH_MAX; call str_cat
    xor r15d, r15d
.Laes_find:
    cmp r15d, [r14 + 4]; jge .Laes_err
    mov rax, r15; imul rax, AENT_SIZE; add rax, [r14 + 24]
    mov rdi, rax; mov rsi, rsp; push rax; call str_cmp; pop rcx
    test eax, eax; jz .Laes_found
    inc r15d; jmp .Laes_find
.Laes_found:
    mov r15, rcx
    mov r8, [r14 + 8]; add r8, [r15 + 256]  # src ptr
    mov r9, [r15 + 264]                      # uncomp size
    cmp dword ptr [r14], 3; jne .Laes_write
    # ZIP local header: skip 30 + fname_len + extra_len
    movzx eax, word ptr [r8 + 26]; movzx edx, word ptr [r8 + 28]
    lea r8, [r8 + 30 + rax]; add r8, rdx
    cmp dword ptr [r15 + 280], 8; jne .Laes_write
    mov rdi, r9; test rdi, rdi; jnz .Laes_az; mov edi, 1
.Laes_az:
    push r8; call mem_alloc; pop r8
    test rax, rax; jz .Laes_err
    push rax
    mov rdi, r8; mov rsi, [r15 + 272]; mov rdx, rax; mov rcx, r9
    call inflate_raw
    pop r8
    test rax, rax; js .Laes_err_free
    mov r9, rax; jmp .Laes_wtmp
.Laes_err_free:
    mov rdi, r8; call mem_free; jmp .Laes_err
.Laes_write:
    xor eax, eax              # flag: r8 not allocated
.Laes_wtmp:
    push r8; push r9; push rax
    mov rdi, r12; lea rsi, [rip + arc_tmp_path]; mov edx, PATH_MAX; call str_copy
    mov edi, AT_FDCWD; mov rsi, r12; mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0600; OS_OPENAT
    test rax, rax; js .Laes_wfail
    mov rbx, rax
    mov rdi, rbx; mov rsi, [rsp + 16]; mov rdx, [rsp + 8]; OS_WRITE
    mov edi, ebx; OS_CLOSE
    pop rax; pop r9; pop r8
    test rax, rax; jz .Laes_ok
    mov rdi, r8; call mem_free
.Laes_ok:
    xor eax, eax; jmp .Laes_ret
.Laes_wfail:
    pop rax; pop r9; pop r8
    test rax, rax; jz .Laes_err
    mov rdi, r8; call mem_free
.Laes_err:
    mov eax, -1
.Laes_ret:
    add rsp, PATH_MAX; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
