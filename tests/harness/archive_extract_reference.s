# Frozen reference oracle: the hand-written asm that src/fs/archive_parse.c + archive_vfs.c replaced (tests/test_c_archive.py diffs against it)
# src/fs/archive_vfs.s - Virtual File System for .tar, .tar.gz, .zip archives — archive extract (split from archive_vfs.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "try_using.inc"
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
.extern tmp_open_unique

.section .rodata
arc_tmp_pfx:   .asciz "arc_view"
arc_tmp_sfx:   .asciz ".tmp"

.section .text
.global arc_enter_model
.global arc_extract_entry
.global arc_zip64_eocd
.global arc_zip64_extra

arc_load_raw_ctx:
    push rbx; push r12; sub rsp, 24
    mov rbx, rdi; mov r12, rsi
    mov edi, ARC_MAX_ENTRIES * AENT_SIZE; call mem_alloc
    mov [rbx + 24], rax; test rax, rax; jz 1f
    mov edi, ARC_MAX_FILE; call mem_alloc
    mov [rbx + 8], rax; test rax, rax; jz 1f
    mov rdi, r12; mov rsi, rax; mov edx, ARC_MAX_FILE; lea rcx, [rbx + 16]
    call fs_read_file_head
    test rax, rax; js 1f; cmp qword ptr [rbx + 16], 0; jle 1f
    cmp dword ptr [rbx], 2; jne 2f
    mov rdi, [rbx + 8]; mov rsi, [rbx + 16]; mov rdx, rsp
    call arc_ungzip; test rax, rax; jz 1f
    push rax; mov rdi, [rbx + 8]; call mem_free; pop rax
    mov [rbx + 8], rax; mov rax, [rsp]; mov [rbx + 16], rax
2:  xor eax, eax; add rsp, 24; pop r12; pop rbx; ret
1:  mov rdi, [rbx + 8]; call mem_free; mov rdi, [rbx + 24]; call mem_free
    mov rdi, rbx; call mem_free; mov eax, -1; add rsp, 24; pop r12; pop rbx; ret

# int arc_enter_model(DirModel *m, const FileEntry *ent) -> 1 if handled, 2 if '..' nav_up, 0 otherwise
arc_enter_model:
    push rbx; push r12; push r13; push r14; sub rsp, PATH_MAX + 16 + TRY_FRAME_SIZE
    mov r13, rdi; mov r14, rsi
    xor r12d, r12d
    test r14, r14; jz .Lahe_no
    call DirModel_entry_name
    cmp dword ptr [r13 + DirModel.virtual_mode], 2
    je .Lahe_in_arc
    test dword ptr [r14 + FileEntry.flags], FE_IS_DIR; jnz .Lahe_no
    cmp qword ptr [r14 + FileEntry.size], ARC_MAX_FILE
    seta r12b
    mov r14, rax
    mov rdi, r14; call arc_is_archive; test eax, eax; jz .Lahe_no
    mov [rsp + PATH_MAX], eax
    mov rdi, rsp; lea rsi, [r13 + DirModel.path]; mov rdx, r14; mov ecx, PATH_MAX
    call path_join # path-checked
    test rax, rax; js .Lahe_no
    mov rdi, r13; call arc_free_ctx
    mov edi, ACTX_SIZE; call mem_alloc; test rax, rax; jz .Lahe_no
    mov r14, rax
    mov rdi, r14; mov esi, ACTX_SIZE; call mem_zero
    mov eax, [rsp + PATH_MAX]; mov [r14], eax
    mov rdi, r14; mov rsi, rsp; call arc_load_raw_ctx
    test eax, eax; js .Lahe_no
    lea rdi, [r14 + ACTX_ORIG]; lea rsi, [r13 + DirModel.path]; mov edx, PATH_MAX; call str_copy
    lea rdi, [r14 + ACTX_FILE]; mov rsi, rsp; mov edx, PATH_MAX; call str_copy
    mov [r13 + DirModel.arc_ctx], r14
    lea r8, [rsp + PATH_MAX + 16]
    TRY_BEGIN r8, .Lahe_fault
    mov rdi, r14
    cmp dword ptr [r14], 3; je .Lahe_pz
    call arc_parse_tar; jmp .Lahe_pop
.Lahe_pz:
    call arc_parse_zip
.Lahe_pop:
    lea r8, [rsp + PATH_MAX + 16]; TRY_END r8
    mov rdi, r13; call arc_populate
    mov eax, 1; test r12d, r12d; jz .Lahe_ret; mov eax, 3; jmp .Lahe_ret
.Lahe_fault:
    mov rdi, r13; call arc_free_ctx; xor eax, eax; jmp .Lahe_ret
.Lahe_in_arc:
    test dword ptr [r14 + FileEntry.flags], FE_IS_PARENT; jz .Lahe_sub
    mov eax, 2; jmp .Lahe_ret
.Lahe_sub:
    test dword ptr [r14 + FileEntry.flags], FE_IS_DIR; jz .Lahe_no
    mov rcx, [r13 + DirModel.arc_ctx]
    lea rdi, [rcx + ACTX_SUB]; mov rsi, rax; mov edx, PATH_MAX; call str_cat
    mov rcx, [r13 + DirModel.arc_ctx]
    lea rdi, [rcx + ACTX_SUB]; call str_len
    cmp rax, PATH_MAX - 2; jae .Lahe_sub_ok
    mov byte ptr [rcx + ACTX_SUB + rax], '/'; mov byte ptr [rcx + ACTX_SUB + rax + 1], 0
.Lahe_sub_ok:
    mov rdi, r13; call arc_populate
    mov eax, 1
    test r12d, r12d; jz .Lahe_ret
    mov eax, 3
    jmp .Lahe_ret
.Lahe_no:
    xor eax, eax
.Lahe_ret:
    add rsp, PATH_MAX + 16 + TRY_FRAME_SIZE; pop r14; pop r13; pop r12; pop rbx; ret

# int arc_write_all(int fd, const void *buf, size_t len) -> 0 on ok, -1 on err
arc_write_all:
    push rbx; push r12; push r13
    mov ebx, edi; mov r12, rsi; mov r13, rdx
.Lawa_loop:
    test r13, r13; jz .Lawa_ok
    mov edi, ebx; mov rsi, r12; mov rdx, r13
    OS_WRITE
    cmp rax, -4; je .Lawa_loop  # -EINTR
    test rax, rax; jle .Lawa_err
    add r12, rax; sub r13, rax
    jmp .Lawa_loop
.Lawa_ok:
    xor eax, eax; jmp .Lawa_ret
.Lawa_err:
    mov eax, -1
.Lawa_ret:
    pop r13; pop r12; pop rbx; ret

# int arc_extract_entry(DirModel *m, const FileEntry *ent, char *out_tmp_path) -> 0 on ok, -1 on err
arc_extract_entry:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX + TRY_FRAME_SIZE + 24
    mov r13, rdi; mov rax, rsi; mov r12, rdx
    SCOPED_MEM_INIT [rsp + PATH_MAX + TRY_FRAME_SIZE]
    USING_FD_INIT [rsp + PATH_MAX + TRY_FRAME_SIZE + 8]
    cmp dword ptr [r13 + DirModel.virtual_mode], 2; jne .Laes_err
    test rax, rax; jz .Laes_err; test dword ptr [rax + FileEntry.flags], FE_IS_DIR; jnz .Laes_err
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
    mov rcx, [r14 + 16]                      # raw_len
    mov rdx, [r15 + 256]                     # offset
    cmp rdx, rcx; ja .Laes_err
    mov r8, [r14 + 8]; add r8, rdx           # src ptr
    sub rcx, rdx                             # avail = raw_len - offset
    mov r9, [r15 + 264]                      # uncomp size
    lea r10, [rsp + PATH_MAX]
    TRY_BEGIN r10, .Laes_fault
    cmp dword ptr [r14], 3; jne .Laes_tar_clamp
    cmp rcx, 30; jb .Laes_fault_end
    movzx eax, word ptr [r8 + 26]; movzx edx, word ptr [r8 + 28]
    lea rax, [rax + rdx + 30]
    cmp rcx, rax; jb .Laes_fault_end
    add r8, rax; sub rcx, rax                # avail -= local hdr
    mov rsi, [r15 + 272]                     # comp_size
    cmp rsi, rcx; jbe .Laes_cs_ok; mov rsi, rcx
.Laes_cs_ok:
    cmp dword ptr [r15 + 280], 8; je .Laes_deflate
    cmp dword ptr [r15 + 280], 0; jne .Laes_fault_end
    cmp r9, rsi; jbe .Laes_tar_clamp; mov r9, rsi
.Laes_tar_clamp:
    cmp r9, rcx; jbe .Laes_wtmp; mov r9, rcx
    jmp .Laes_wtmp
.Laes_deflate:
    cmp r9, ARC_MAX_UNCOMP; ja .Laes_fault_end
    mov rdi, r9; test rdi, rdi; jnz 1f; mov edi, 1
1:  push r8; push rsi; push r9; sub rsp, 8          # mem_alloc clobbers r9: it is inflate's output capacity
    call mem_alloc
    add rsp, 8; pop r9; pop rsi; pop r8
    test rax, rax; jz .Laes_fault_end
    SCOPED_MEM_SET [rsp + PATH_MAX + TRY_FRAME_SIZE], rax
    mov rdi, r8; mov rdx, rax; mov rcx, r9; call inflate_raw
    test rax, rax; js .Laes_fault_end
    mov r8, [rsp + PATH_MAX + TRY_FRAME_SIZE]; mov r9, rax
.Laes_wtmp:
    push r8; push r9
    lea rdi, [rip + arc_tmp_pfx]; lea rsi, [rip + arc_tmp_sfx]
    mov rdx, r12; mov ecx, PATH_MAX; call tmp_open_unique
    pop r9; pop r8; test rax, rax; js .Laes_fault_end
    USING_FD_SET [rsp + PATH_MAX + TRY_FRAME_SIZE + 8], eax
    mov edi, eax; mov rsi, r8; mov rdx, r9; call arc_write_all
    test eax, eax; js .Laes_fault_end
    USING_FD_CLOSE [rsp + PATH_MAX + TRY_FRAME_SIZE + 8]
    SCOPED_MEM_FREE [rsp + PATH_MAX + TRY_FRAME_SIZE]
    lea r10, [rsp + PATH_MAX]; TRY_END r10
    xor eax, eax; jmp .Laes_ret
.Laes_fault_end:
    lea r10, [rsp + PATH_MAX]; TRY_END r10
.Laes_fault:
    USING_FD_CLOSE [rsp + PATH_MAX + TRY_FRAME_SIZE + 8]
    SCOPED_MEM_FREE [rsp + PATH_MAX + TRY_FRAME_SIZE]
.Laes_err:
    mov eax, -1
.Laes_ret:
    add rsp, PATH_MAX + TRY_FRAME_SIZE + 24; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# (cd_off in rax, total_entries in rdx) arc_zip64_eocd(r12=rdi, r13=rsi, eocd_off=rdx, cd_off=rcx, total=r8)
arc_zip64_eocd:
    mov rax, rcx; mov r10, rdx; mov rdx, r8
    cmp r10, 20; jb .Lz64e_ret
    cmp dword ptr [rdi + r10 - 20], 0x07064b50; jne .Lz64e_ret
    mov r9, [rdi + r10 - 12]       # z64_eocd_off
    cmp r9, rsi; ja .Lz64e_ret
    mov rcx, rsi; sub rcx, r9; cmp rcx, 56; jb .Lz64e_ret
    cmp dword ptr [rdi + r9], 0x06064b50; jne .Lz64e_ret
    mov rdx, [rdi + r9 + 32]        # total_entries
    cmp rdx, ARC_MAX_ENTRIES; jbe .Lz64e_off
    mov edx, ARC_MAX_ENTRIES
.Lz64e_off:
    mov rax, [rdi + r9 + 48]        # cd_off
.Lz64e_ret:
    ret

# Apply ZIP64 Extra Field (0x0001) to entry [rdi] using CD at r12+r15, fname=rcx, extra=r10
arc_zip64_extra:
    mov edx, 0xFFFFFFFF
    cmp [rdi + 264], rdx; je .Lz64x_scan
    cmp [rdi + 272], rdx; je .Lz64x_scan
    cmp [rdi + 256], rdx; jne .Lz64x_ret
.Lz64x_scan:
    lea rsi, [r15 + 46 + rcx]
    lea rax, [rsi + r10]; cmp rax, r13; ja .Lz64x_ret
    add rsi, r12                    # extra ptr
    mov r8, r10                     # extra rem
.Lz64x_loop:
    cmp r8, 4; jb .Lz64x_ret
    movzx eax, word ptr [rsi]
    movzx r9d, word ptr [rsi + 2]
    add rsi, 4; sub r8, 4
    cmp r9, r8; ja .Lz64x_ret
    cmp ax, 1; je .Lz64x_hit
    add rsi, r9; sub r8, r9; jmp .Lz64x_loop
.Lz64x_hit:
    cmp [rdi + 264], rdx; jne .Lz64x_cs
    cmp r9, 8; jb .Lz64x_ret
    mov rax, [rsi]; mov [rdi + 264], rax; add rsi, 8; sub r9, 8
.Lz64x_cs:
    cmp [rdi + 272], rdx; jne .Lz64x_off
    cmp r9, 8; jb .Lz64x_ret
    mov rax, [rsi]; mov [rdi + 272], rax; add rsi, 8; sub r9, 8
.Lz64x_off:
    cmp [rdi + 256], rdx; jne .Lz64x_ret
    cmp r9, 8; jb .Lz64x_ret
    mov rax, [rsi]; mov [rdi + 256], rax
.Lz64x_ret:
    ret
