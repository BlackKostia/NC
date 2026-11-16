# src/fs/archive_vfs.s - Virtual File System for .tar, .tar.gz, .zip archives

# ArcEntry (288 bytes): [0..255]=name, [256]=off(8), [264]=size(8), [272]=comp_size(8), [280]=method(4), [284]=is_dir(4)
# ArcCtx: [0]=type(4), [4]=cnt(4), [8]=raw_buf(8), [16]=raw_len(8), [24]=entries(8),
#         [32..+PATH_MAX]=sub_dir, [+PATH_MAX..+2*PATH_MAX]=orig_dir, [+2*PATH_MAX..+3*PATH_MAX]=arc_file

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
arc_ext_tar:   .asciz ".tar"
arc_ext_tgz:   .asciz ".tgz"
arc_ext_targz: .asciz ".tar.gz"
arc_ext_zip:   .asciz ".zip"
arc_dotdot:    .asciz ".."

.section .text
.global arc_is_archive
.global arc_parse_tar
.global arc_parse_zip
.global arc_ungzip
.global arc_populate
.global arc_free_ctx
.global arc_nav_up_model

# int arc_ends_ci(const char *s, size_t len, const char *sfx, size_t sfx_len)
arc_ends_ci:
    cmp rsi, rcx; jb .Laec_no
    sub rsi, rcx; add rdi, rsi; mov rsi, rdx
    call str_casecmp
    test eax, eax; jnz .Laec_no
    mov eax, 1; ret
.Laec_no:
    xor eax, eax; ret

# int arc_is_archive(const char *name) -> 1=tar, 2=tar.gz/tgz, 3=zip, 0=none
arc_is_archive:
    push rbx; push r12
    mov rbx, rdi; call str_len; mov r12, rax
    mov rdi, rbx; mov rsi, r12; lea rdx, [rip + arc_ext_targz]; mov ecx, 7
    call arc_ends_ci; test eax, eax; jnz .Laia_tgz
    mov rdi, rbx; mov rsi, r12; lea rdx, [rip + arc_ext_tgz]; mov ecx, 4
    call arc_ends_ci; test eax, eax; jnz .Laia_tgz
    mov rdi, rbx; mov rsi, r12; lea rdx, [rip + arc_ext_tar]; mov ecx, 4
    call arc_ends_ci; test eax, eax; jnz .Laia_tar
    mov rdi, rbx; mov rsi, r12; lea rdx, [rip + arc_ext_zip]; mov ecx, 4
    call arc_ends_ci; test eax, eax; jnz .Laia_zip
    xor eax, eax; pop r12; pop rbx; ret
.Laia_tar: mov eax, 1; pop r12; pop rbx; ret
.Laia_tgz: mov eax, 2; pop r12; pop rbx; ret
.Laia_zip: mov eax, 3; pop r12; pop rbx; ret

# uint64_t arc_octal(const char *p, int n)
arc_octal:
    xor eax, eax; xor ecx, ecx
.Lao_loop:
    cmp ecx, esi; jge .Lao_ret
    movzx edx, byte ptr [rdi + rcx]
    test dl, dl; jz .Lao_ret
    cmp dl, ' '; je .Lao_next
    cmp dl, '0'; jb .Lao_ret
    cmp dl, '7'; ja .Lao_ret
    shl rax, 3; sub dl, '0'; add rax, rdx
.Lao_next:
    inc ecx; jmp .Lao_loop
.Lao_ret:
    ret

# void arc_parse_tar(ArcCtx *ctx)
arc_parse_tar:
    push rbx; push r12; push r13; push r14
    mov rbx, rdi
    mov r12, [rbx + 8]        # raw_buf
    mov r13, [rbx + 16]       # raw_len
    xor r14d, r14d            # off = 0
.Lapt_loop:
    lea rax, [r14 + 512]; cmp rax, r13; ja .Lapt_done
    lea rdi, [r12 + r14]
    cmp byte ptr [rdi], 0; je .Lapt_done
    mov eax, [rbx + 4]; cmp eax, ARC_MAX_ENTRIES; jge .Lapt_done
    imul rax, AENT_SIZE; add rax, [rbx + 24]
    push rax
    mov rdi, rax; lea rsi, [r12 + r14]; mov edx, 100; call str_copy
    lea rdi, [r12 + r14 + 124]; mov esi, 12; call arc_octal
    pop rcx                   # entry
    lea rdx, [r14 + 512]      # data_off
    mov r8, r13
    sub r8, rdx               # avail = raw_len - data_off
    cmp rax, r8
    jbe .Lapt_sz_ok
    mov rax, r8               # clamp size to buffer
.Lapt_sz_ok:
    mov [rcx + 264], rax      # size
    mov [rcx + 256], rdx      # data_off
    mov [rcx + 272], rax      # comp_size
    mov dword ptr [rcx + 280], 0
    movzx edx, byte ptr [r12 + r14 + 156]
    xor r8d, r8d; cmp edx, '5'; sete r8b
    mov [rcx + 284], r8d
    inc dword ptr [rbx + 4]
    add rax, 511; and rax, -512
    lea r14, [r14 + 512 + rax]
    jmp .Lapt_loop
.Lapt_done:
    pop r14; pop r13; pop r12; pop rbx; ret

# void arc_parse_zip(ArcCtx *ctx)
arc_parse_zip:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; mov r12, [rbx + 8]; mov r13, [rbx + 16]
    cmp r13, 22; jb .Lapz_done
    lea r14, [r13 - 22]
    xor ecx, ecx
.Lapz_eocd:
    cmp dword ptr [r12 + r14], 0x06054b50; je .Lapz_cd
    test r14, r14; jz .Lapz_done
    dec r14; inc ecx; cmp ecx, 65536; jge .Lapz_done; jmp .Lapz_eocd
.Lapz_cd:
    mov r15d, [r12 + r14 + 16]  # cd_off
    movzx r8d, word ptr [r12 + r14 + 10]  # total_entries
    xor r9d, r9d
.Lapz_loop:
    cmp r9d, r8d; jge .Lapz_done
    lea rax, [r15 + 46]; cmp rax, r13; ja .Lapz_done
    cmp dword ptr [r12 + r15], 0x02014b50; jne .Lapz_done
    mov eax, [rbx + 4]; cmp eax, ARC_MAX_ENTRIES; jge .Lapz_done
    imul rax, AENT_SIZE; add rax, [rbx + 24]
    movzx ecx, word ptr [r12 + r15 + 10]; mov [rax + 280], ecx  # method
    mov ecx, [r12 + r15 + 20]; mov [rax + 272], rcx             # comp_size
    mov ecx, [r12 + r15 + 24]; mov [rax + 264], rcx             # uncomp_size
    mov ecx, [r12 + r15 + 42]; mov [rax + 256], rcx             # local_hdr_off
    movzx ecx, word ptr [r12 + r15 + 28]                        # fname_len
    movzx r10d, word ptr [r12 + r15 + 30]                       # extra_len
    movzx r11d, word ptr [r12 + r15 + 32]                       # comment_len
    lea rdx, [r15 + 46 + rcx]; cmp rdx, r13; ja .Lapz_done
    push r8; push r9; push r10; push r11; push rcx
    mov rdx, rcx; cmp rdx, 255; jbe .Lapz_nm; mov edx, 255
.Lapz_nm:
    mov rdi, rax; lea rsi, [r12 + r15 + 46]; inc rdx
    push rax; call str_copy; pop rax
    pop rcx; pop r11; pop r10; pop r9; pop r8
    push rcx
    mov rdi, rax; call str_len
    pop rcx
    xor edx, edx
    test rax, rax; jz .Lapz_nd
    cmp byte ptr [rdi + rax - 1], '/'; jne .Lapz_nd
    mov edx, 1
.Lapz_nd:
    mov [rdi + 284], edx
    # Validate local header + data bounds against raw_len (r13)
    mov rdx, [rdi + 256]      # local_hdr_off
    lea r14, [rdx + 30]
    cmp r14, r13; ja .Lapz_skip
    movzx eax, word ptr [r12 + rdx + 26]
    add r14, rax
    movzx eax, word ptr [r12 + rdx + 28]
    add r14, rax              # data_off = off + 30 + fname + extra
    cmp r14, r13; ja .Lapz_skip
    mov rax, r13; sub rax, r14  # avail = raw_len - data_off
    cmp [rdi + 272], rax; jbe .Lapz_cs_ok
    mov [rdi + 272], rax      # clamp comp_size to avail
.Lapz_cs_ok:
    cmp dword ptr [rdi + 280], 0; jne .Lapz_keep
    mov rdx, [rdi + 272]
    cmp [rdi + 264], rdx; jbe .Lapz_keep
    mov [rdi + 264], rdx      # stored: clamp uncomp_size <= comp_size
.Lapz_keep:
    inc dword ptr [rbx + 4]
.Lapz_skip:
    add r15, 46
    add r15, rcx
    add r15, r10
    add r15, r11
    inc r9d; jmp .Lapz_loop
.Lapz_done:
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# void *arc_ungzip(const uint8_t *src, uint64_t src_len, uint64_t *out_len)
arc_ungzip:
    push rbx; push r12; push r13
    cmp rsi, 18; jb .Laug_fail
    cmp word ptr [rdi], 0x8B1F; jne .Laug_fail
    cmp byte ptr [rdi + 2], 8; jne .Laug_fail
    movzx ecx, byte ptr [rdi + 3]  # flg
    mov r8d, 10
    test ecx, 4; jz .Laug_nm       # FEXTRA
    lea rax, [r8 + 2]; cmp rax, rsi; ja .Laug_fail
    movzx eax, word ptr [rdi + r8]; lea r8, [r8 + 2 + rax]
.Laug_nm:
    test ecx, 8; jz .Laug_cm       # FNAME
.Laug_nml:
    cmp r8, rsi; jae .Laug_fail
    cmp byte ptr [rdi + r8], 0; lea r8, [r8 + 1]; jne .Laug_nml
.Laug_cm:
    test ecx, 16; jz .Laug_hc      # FCOMMENT
.Laug_cml:
    cmp r8, rsi; jae .Laug_fail
    cmp byte ptr [rdi + r8], 0; lea r8, [r8 + 1]; jne .Laug_cml
.Laug_hc:
    test ecx, 2; jz .Laug_go
    add r8, 2
.Laug_go:
    lea rax, [r8 + 8]; cmp rax, rsi; ja .Laug_fail
    mov ebx, [rdi + rsi - 4]       # ISIZE
    cmp ebx, 65536; jae .Laug_cap; mov ebx, 65536
.Laug_cap:
    cmp ebx, 8388608; jbe .Laug_al; mov ebx, 8388608
.Laug_al:
    mov r12, rdi; mov r13, rsi; push rdx; push r8
    mov edi, ebx; call mem_alloc; pop r8; pop rdx
    test rax, rax; jz .Laug_fail
    push rax; push rdx
    lea rdi, [r12 + r8]; mov rsi, r13; sub rsi, r8; sub rsi, 8
    mov rdx, rax; mov rcx, rbx
    call inflate_raw
    pop rdx; pop rcx
    test rax, rax; js .Laug_free
    mov [rdx], rax; mov rax, rcx
    pop r13; pop r12; pop rbx; ret
.Laug_free:
    mov rdi, rcx; call mem_free
.Laug_fail:
    xor eax, eax; pop r13; pop r12; pop rbx; ret

# void arc_populate(DirModel *m)
arc_populate:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX + FileStat._size + 16
    mov r12, rdi              # DirModel*
    mov r13, [r12 + DirModel.arc_ctx]
    mov rdi, r12; call DirModel_cancel_load
    mov qword ptr [r12 + DirModel.raw_count], 0
    mov qword ptr [r12 + DirModel.count], 0
    mov qword ptr [r12 + DirModel.name_used], 0
    mov qword ptr [r12 + DirModel.total_bytes], 0
    mov dword ptr [r12 + DirModel.dir_count], 0
    mov dword ptr [r12 + DirModel.file_count], 0
    mov dword ptr [r12 + DirModel.virtual_mode], 2
    mov dword ptr [r12 + DirModel.stats_complete], 1
    lea rdi, [r12 + DirModel.path]; lea rsi, [r13 + ACTX_FILE]
    mov edx, PATH_MAX; call str_copy

    # Add ".."
    lea rdi, [rsp + PATH_MAX]; mov esi, FileStat._size; call mem_zero
    mov dword ptr [rsp + PATH_MAX + FileStat.mode], S_IFDIR | 0755
    mov rdi, r12; lea rsi, [rip + arc_dotdot]; lea rdx, [rsp + PATH_MAX]
    call ds_append_entry

    lea rdi, [r13 + ACTX_SUB]; call str_len; mov [rsp + PATH_MAX + FileStat._size], rax
    xor r14d, r14d
.Lap_loop:
    cmp r14d, [r13 + 4]; jge .Lap_done
    mov rax, r14; imul rax, AENT_SIZE; add rax, [r13 + 24]
    mov r15, rax              # entry
    lea rdi, [r15]; lea rsi, [r13 + ACTX_SUB]
    cmp qword ptr [rsp + PATH_MAX + FileStat._size], 0; je .Lap_strip
    call str_starts_with; test eax, eax; jz .Lap_next
.Lap_strip:
    mov rcx, [rsp + PATH_MAX + FileStat._size]
    lea rsi, [r15 + rcx]
    cmp byte ptr [rsi], 0; je .Lap_next
    mov rdi, rsp; mov edx, PATH_MAX; call str_copy
    # Check if '/' inside remainder -> directory component
    xor ecx, ecx; xor r8d, r8d
.Lap_slash:
    mov al, [rsp + rcx]; test al, al; jz .Lap_chk_dup
    cmp al, '/'; jne .Lap_sn
    mov byte ptr [rsp + rcx], 0; mov r8d, 1; jmp .Lap_chk_dup
.Lap_sn:
    inc ecx; jmp .Lap_slash
.Lap_chk_dup:
    cmp byte ptr [rsp], 0; je .Lap_next
    push r8
    mov rdi, r12; lea rsi, [rsp + 8]; call DirModel_find_by_name
    pop r8
    cmp rax, 0; jge .Lap_next
    lea rdi, [rsp + PATH_MAX]; mov esi, FileStat._size; call mem_zero
    test r8d, r8d; jnz .Lap_isdir
    cmp dword ptr [r15 + 284], 0; jne .Lap_isdir
    mov dword ptr [rsp + PATH_MAX + FileStat.mode], S_IFREG | 0644
    mov rax, [r15 + 264]; mov [rsp + PATH_MAX + FileStat.size], rax
    jmp .Lap_add
.Lap_isdir:
    mov dword ptr [rsp + PATH_MAX + FileStat.mode], S_IFDIR | 0755
.Lap_add:
    mov rdi, r12; mov rsi, rsp; lea rdx, [rsp + PATH_MAX]
    call ds_append_entry
.Lap_next:
    inc r14d; jmp .Lap_loop
.Lap_done:
    mov rdi, r12; call DirModel_apply_filter
    mov rdi, r12; call DirModel_sort
    add rsp, PATH_MAX + FileStat._size + 16
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# void arc_free_ctx(DirModel *m)
arc_free_ctx:
    push rbx; mov rbx, [rdi + DirModel.arc_ctx]
    test rbx, rbx; jz .Lafc_ret
    mov qword ptr [rdi + DirModel.arc_ctx], 0
    mov rdi, [rbx + 8]; test rdi, rdi; jz .Lafc_e; call mem_free
.Lafc_e:
    mov rdi, [rbx + 24]; test rdi, rdi; jz .Lafc_c; call mem_free
.Lafc_c:
    mov rdi, rbx; call mem_free
.Lafc_ret:
    pop rbx; ret

# int arc_nav_up_model(DirModel *m) -> -1 if not arc, else cursor (>=0)
arc_nav_up_model:
    cmp dword ptr [rdi + DirModel.virtual_mode], 2
    jne .Lanu_no
    push rbx; push r12; sub rsp, PATH_MAX * 2
    mov rbx, rdi; mov r12, [rbx + DirModel.arc_ctx]
    lea rdi, [r12 + ACTX_SUB]; call str_len
    test rax, rax; jz .Lanu_exit
    dec rax
.Lanu_strip:
    test rax, rax; jz .Lanu_zero
    cmp byte ptr [r12 + ACTX_SUB + rax - 1], '/'; je .Lanu_cut
    dec rax; jmp .Lanu_strip
.Lanu_zero:
    mov byte ptr [r12 + ACTX_SUB], 0; jmp .Lanu_pop
.Lanu_cut:
    mov byte ptr [r12 + ACTX_SUB + rax], 0
.Lanu_pop:
    mov rdi, rbx; call arc_populate
    xor eax, eax; add rsp, PATH_MAX * 2; pop r12; pop rbx; ret
.Lanu_exit:
    mov rdi, rsp; lea rsi, [r12 + ACTX_ORIG]; mov edx, PATH_MAX; call str_copy
    lea rdi, [r12 + ACTX_FILE]; call path_basename
    lea rdi, [rsp + PATH_MAX]; mov rsi, rax; mov edx, PATH_MAX; call str_copy
    mov rdi, rbx; mov dword ptr [rdi + DirModel.virtual_mode], 0
    call arc_free_ctx
    mov rdi, rbx; mov rsi, rsp; call DirModel_chdir
    mov rdi, rbx; lea rsi, [rsp + PATH_MAX]; call DirModel_find_by_name
    test eax, eax; jns .Lanu_ret
    xor eax, eax
.Lanu_ret:
    add rsp, PATH_MAX * 2; pop r12; pop rbx; ret
.Lanu_no:
    mov eax, -1; ret
