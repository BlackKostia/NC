# src/fs/pkg_vfs_pane.s - Interactive FilePane VFS provider (virtual_mode = 3)
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
pkvp_manifest: .asciz "manifest.ini"
pkvp_k_kind:   .asciz "kind"
pkvp_k_scheme: .asciz "vfs_scheme"
pkvp_k_exec:   .asciz "exec"
pkvp_v_vfs:    .asciz "vfs"
pkvp_cmd_list: .asciz "LIST"
pkvp_cmd_read: .asciz "READ"
pkvp_sep_uri:  .asciz "://"
pkvp_dotdot:   .asciz ".."
pkvp_tmp_view: .asciz "/tmp/duop_vfs_view"

.section .text
.global pkg_vfs_find_by_uri
.global pkg_vfs_load_dir
.global pkg_vfs_parent_uri
.global pkg_vfs_read_uri

.extern DirModel_cancel_load
.extern DirModel_sort
.extern ds_append_entry
.extern fs_read_file_head
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern os_dir_next_ex
.extern os_dir_read
.extern os_poll_in
.extern path_join
.extern pkg_get_root
.extern str_cmp
.extern str_copy
.extern str_len
.extern str_starts_with

pkvp_trim_cp:
    cmp rdi, rsi; jae .Lpvt3_r
.Lpvt3_l:
    mov al, [rdi]; cmp al, ' '; je .Lpvt3_la; cmp al, 9; je .Lpvt3_la; jmp .Lpvt3_r
.Lpvt3_la:
    inc rdi; cmp rdi, rsi; jb .Lpvt3_l
.Lpvt3_r:
    cmp rsi, rdi; jbe .Lpvt3_cp
    mov al, [rsi - 1]; cmp al, ' '; je .Lpvt3_rd; cmp al, 9; je .Lpvt3_rd; cmp al, 13; je .Lpvt3_rd; jmp .Lpvt3_cp
.Lpvt3_rd:
    dec rsi; jmp .Lpvt3_r
.Lpvt3_cp:
    xor eax, eax; dec ecx
.Lpvt3_loop:
    cmp eax, ecx; jge .Lpvt3_end; cmp rdi, rsi; jae .Lpvt3_end
    mov r8b, [rdi]; mov [rdx + rax], r8b; inc rdi; inc eax; jmp .Lpvt3_loop
.Lpvt3_end:
    mov byte ptr [rdx + rax], 0; ret

# void pkvp_parse(buf, len, kind32, scheme64, exec64)
pkvp_parse:
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 80
    mov r12, rdi; movsxd rax, esi; lea r13, [r12 + rax]
    mov r14, rdx; mov r15, rcx; mov [rsp + 64], r8
    mov byte ptr [r14], 0; mov byte ptr [r15], 0; mov byte ptr [r8], 0
.Lpvp_l:
    cmp r12, r13; jae .Lpvp_d
    mov rbx, r12
.Lpvp_e:
    cmp rbx, r13; jae .Lpvp_g; cmp byte ptr [rbx], 10; je .Lpvp_g; inc rbx; jmp .Lpvp_e
.Lpvp_g:
    mov rcx, r12
.Lpvp_q:
    cmp rcx, rbx; jae .Lpvp_n; cmp byte ptr [rcx], '='; je .Lpvp_kv; inc rcx; jmp .Lpvp_q
.Lpvp_kv:
    push rbx; push rcx
    mov rdi, r12; mov rsi, rcx; lea rdx, [rsp + 32]; mov ecx, 64; call pkvp_trim_cp
    lea rdi, [rsp + 32]; lea rsi, [rip + pkvp_k_kind]; call str_cmp
    pop rcx; pop rbx; test eax, eax; jnz .Lpvp_s
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, r14; mov ecx, 32; call pkvp_trim_cp; jmp .Lpvp_n
.Lpvp_s:
    push rbx; push rcx
    lea rdi, [rsp + 32]; lea rsi, [rip + pkvp_k_scheme]; call str_cmp
    pop rcx; pop rbx; test eax, eax; jnz .Lpvp_x
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, r15; mov ecx, 64; call pkvp_trim_cp; jmp .Lpvp_n
.Lpvp_x:
    push rbx; push rcx
    lea rdi, [rsp + 32]; lea rsi, [rip + pkvp_k_exec]; call str_cmp
    pop rcx; pop rbx; test eax, eax; jnz .Lpvp_n
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, [rsp + 64]; mov ecx, 64; call pkvp_trim_cp
.Lpvp_n:
    lea r12, [rbx + 1]; jmp .Lpvp_l
.Lpvp_d:
    add rsp, 80; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_vfs_find_by_uri(char **envp, const char *uri, char *exe_out) -> 0 ok, -1 err
pkg_vfs_find_by_uri:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16384 + 4096 + 216
    mov [rsp + 192], rdi; mov [rsp + 200], rsi; mov r12, rdx
    lea rsi, [rsp + 216]; mov edx, PATH_MAX; call pkg_get_root
    mov edi, AT_FDCWD; lea rsi, [rsp + 216]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lpfu_no
    mov ebx, eax
.Lpfu_rd:
    mov edi, ebx; lea rsi, [rsp + 216 + PATH_MAX * 2]; mov edx, 16384; call os_dir_read
    test rax, rax; jle .Lpfu_close_no
    mov [rsp], rax; mov qword ptr [rsp + 8], 0
.Lpfu_ent:
    lea rdi, [rsp + 216 + PATH_MAX * 2]; mov rsi, [rsp]
    lea rdx, [rsp + 8]; lea rcx, [rsp + 16]; lea r8, [rsp + 24]
    call os_dir_next_ex; test rax, rax; jz .Lpfu_rd
    mov r15, rax
    cmp byte ptr [r15], '.'; jne .Lpfu_seg
    cmp byte ptr [r15 + 1], 0; je .Lpfu_ent
    cmp byte ptr [r15 + 1], '.'; jne .Lpfu_seg
    cmp byte ptr [r15 + 2], 0; je .Lpfu_ent
.Lpfu_seg:
    lea rdi, [rsp + 216 + PATH_MAX]; lea rsi, [rsp + 216]; mov rdx, r15; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + 216 + PATH_MAX * 2 + 16384]
    lea rsi, [rsp + 216 + PATH_MAX]; lea rdx, [rip + pkvp_manifest]; mov ecx, 4096; call path_join
    lea rdi, [rsp + 216 + PATH_MAX * 2 + 16384]
    mov rsi, rdi; mov edx, 4096; lea rcx, [rsp + 24]; call fs_read_file_head
    test rax, rax; js .Lpfu_ent
    lea rdi, [rsp + 216 + PATH_MAX * 2 + 16384]; mov esi, [rsp + 24]
    lea rdx, [rsp + 32]; lea rcx, [rsp + 64]; lea r8, [rsp + 128]; call pkvp_parse
    lea rdi, [rsp + 32]; lea rsi, [rip + pkvp_v_vfs]; call str_cmp
    test eax, eax; jnz .Lpfu_ent
    cmp byte ptr [rsp + 64], 0; je .Lpfu_ent
    cmp byte ptr [rsp + 128], 0; je .Lpfu_ent
    mov rdi, [rsp + 200]; lea rsi, [rsp + 64]; call str_starts_with
    test eax, eax; jz .Lpfu_ent
    lea rdi, [rsp + 64]; call str_len
    mov rcx, [rsp + 200]; add rcx, rax
    cmp byte ptr [rcx], ':'; jne .Lpfu_ent
    cmp word ptr [rcx + 1], 0x2F2F; jne .Lpfu_ent
    mov edi, ebx; OS_CLOSE
    mov rdi, r12; lea rsi, [rsp + 216 + PATH_MAX]; lea rdx, [rsp + 128]; mov ecx, PATH_MAX; call path_join
    xor eax, eax; jmp .Lpfu_ret
.Lpfu_close_no:
    mov edi, ebx; OS_CLOSE
.Lpfu_no:
    mov eax, -1
.Lpfu_ret:
    add rsp, PATH_MAX * 2 + 16384 + 4096 + 216; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

pkvp_exec_capture:
    # rdi=exe, rsi=cmd, rdx=uri, rcx=opt_arg4_or_0, r8=envp, r9=buf, [rsp+8]=cap -> bytes or -1
    mov rax, [rsp + 8]
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 72
    mov r12, rdi; mov [rsp + 32], rsi; mov [rsp + 40], rdx; mov [rsp + 48], rcx
    mov [rsp + 56], r8; mov r14, r9; mov r15d, eax
    mov edi, AT_FDCWD; mov rsi, r12; mov edx, 0755; xor r10d, r10d; OS_FCHMODAT
    lea rdi, [rsp + 64]; xor esi, esi; OS_PIPE2
    test rax, rax; js .Lpvec_err
    OS_FORK
    test rax, rax; js .Lpvec_cl; jnz .Lpvec_par
    mov edi, [rsp + 64]; OS_CLOSE
    mov edi, [rsp + 68]; mov esi, 1; OS_DUP2
    mov edi, [rsp + 68]; OS_CLOSE
    mov [rsp], r12
    mov rax, [rsp + 32]; mov [rsp + 8], rax
    mov rax, [rsp + 40]; mov [rsp + 16], rax
    mov rax, [rsp + 48]; mov [rsp + 24], rax
    mov qword ptr [rsp + 32], 0
    mov rdi, r12; mov rsi, rsp; mov rdx, [rsp + 56]; OS_EXECVE
    mov edi, 127; OS_EXIT
.Lpvec_cl:
    mov edi, [rsp + 64]; OS_CLOSE; mov edi, [rsp + 68]; OS_CLOSE; jmp .Lpvec_err
.Lpvec_par:
    mov ebx, eax; mov edi, [rsp + 68]; OS_CLOSE; xor r12d, r12d
.Lpvec_rd:
    cmp r12d, r15d; jge .Lpvec_done
    mov edi, [rsp + 64]; mov esi, 1500; call os_poll_in
    test rax, rax; jle .Lpvec_done
    mov edi, [rsp + 64]; lea rsi, [r14 + r12]; mov edx, r15d; sub edx, r12d; OS_READ
    cmp rax, -EINTR; je .Lpvec_rd
    test rax, rax; jle .Lpvec_done
    add r12d, eax; jmp .Lpvec_rd
.Lpvec_done:
    mov edi, [rsp + 64]; OS_CLOSE
.Lpvec_wait:
    mov edi, ebx; lea rsi, [rsp + 60]; xor edx, edx; xor r10d, r10d; OS_WAIT4
    cmp rax, -EINTR; je .Lpvec_wait
    mov eax, r12d; jmp .Lpvec_ret
.Lpvec_err:
    mov eax, -1
.Lpvec_ret:
    add rsp, 72; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

pkvp_parse_dec:
    xor eax, eax
.Lppd_l:
    cmp rdi, rsi; jae .Lppd_r
    movzx ecx, byte ptr [rdi]
    cmp cl, '0'; jb .Lppd_r; cmp cl, '9'; ja .Lppd_r
    imul rax, rax, 10; sub cl, '0'; add rax, rcx; inc rdi; jmp .Lppd_l
.Lppd_r:
    ret

# int pkg_vfs_load_dir(char **envp, DirModel *model, const char *uri) -> 0 ok, -1 err
pkg_vfs_load_dir:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX + 512 + FileStat._size + 32
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, rbx; mov rsi, r13; mov rdx, rsp; call pkg_vfs_find_by_uri
    test eax, eax; jnz .Lpvld_err
    mov edi, 65536; call mem_alloc; test rax, rax; jz .Lpvld_err
    mov r14, rax
    mov rdi, rsp; lea rsi, [rip + pkvp_cmd_list]; mov rdx, r13; xor ecx, ecx
    mov r8, rbx; mov r9, r14; push 65535; call pkvp_exec_capture; add rsp, 8
    test eax, eax; js .Lpvld_free_err
    mov [rsp + PATH_MAX], eax
    cmp dword ptr [r12 + DirModel.virtual_mode], 3; je .Lpvld_reset
    mov edi, PATH_MAX; call mem_alloc; test rax, rax; jz .Lpvld_reset
    mov [r12 + DirModel.arc_ctx], rax
    mov rdi, rax; lea rsi, [r12 + DirModel.path]; mov edx, PATH_MAX; call str_copy
.Lpvld_reset:
    mov rdi, r12; call DirModel_cancel_load
    mov qword ptr [r12 + DirModel.raw_count], 0; mov qword ptr [r12 + DirModel.count], 0
    mov qword ptr [r12 + DirModel.name_used], 0; mov qword ptr [r12 + DirModel.total_bytes], 0
    mov dword ptr [r12 + DirModel.dir_count], 0; mov dword ptr [r12 + DirModel.file_count], 0
    mov dword ptr [r12 + DirModel.virtual_mode], 3; mov dword ptr [r12 + DirModel.stats_complete], 1
    lea rdi, [r12 + DirModel.path]; mov rsi, r13; mov edx, PATH_MAX; call str_copy
    lea rdi, [rsp + PATH_MAX + 512]; mov esi, FileStat._size; call mem_zero
    mov dword ptr [rsp + PATH_MAX + 512 + FileStat.mode], S_IFDIR | 0755
    mov rdi, r12; lea rsi, [rip + pkvp_dotdot]; lea rdx, [rsp + PATH_MAX + 512]; call ds_append_entry
    mov rbx, r14; mov eax, [rsp + PATH_MAX]; lea r15, [r14 + rax]
.Lpvld_line:
    cmp rbx, r15; jae .Lpvld_sort
    mov r8, rbx
.Lpvld_eol:
    cmp r8, r15; jae .Lpvld_got; cmp byte ptr [r8], 10; je .Lpvld_got; inc r8; jmp .Lpvld_eol
.Lpvld_got:
    cmp r8, rbx; je .Lpvld_next
    push r8
    lea rdi, [rsp + PATH_MAX + 512 + 8]; mov esi, FileStat._size; call mem_zero
    mov rcx, rbx; xor edx, edx; mov r9, [rsp]
.Lpvld_nm:
    cmp rcx, r9; jae .Lpvld_nmd; mov al, [rcx]; cmp al, 9; je .Lpvld_t1; cmp al, 13; je .Lpvld_nms
    cmp edx, 255; jge .Lpvld_nms; mov [rsp + PATH_MAX + 16 + rdx], al; inc edx
.Lpvld_nms:
    inc rcx; jmp .Lpvld_nm
.Lpvld_t1:
    inc rcx
.Lpvld_nmd:
    mov byte ptr [rsp + PATH_MAX + 16 + rdx], 0
    cmp edx, 0; je .Lpvld_pop_next
    mov rdi, rcx; mov rsi, r9; call pkvp_parse_dec
    mov [rsp + PATH_MAX + 512 + 8 + FileStat.size], rax
    mov dword ptr [rsp + PATH_MAX + 512 + 8 + FileStat.mode], S_IFREG | 0644
    mov rcx, rdi
    cmp rcx, r9; jae .Lpvld_add; cmp byte ptr [rcx], 9; jne .Lpvld_add; inc rcx
    mov rdi, rcx; mov rsi, r9; call pkvp_parse_dec
    mov [rsp + PATH_MAX + 512 + 8 + FileStat.mtime], rax
    mov rcx, rdi
    cmp rcx, r9; jae .Lpvld_add; cmp byte ptr [rcx], 9; jne .Lpvld_add; inc rcx
    cmp rcx, r9; jae .Lpvld_add; cmp byte ptr [rcx], 'd'; jne .Lpvld_add
    mov dword ptr [rsp + PATH_MAX + 512 + 8 + FileStat.mode], S_IFDIR | 0755
.Lpvld_add:
    mov rdi, r12; lea rsi, [rsp + PATH_MAX + 16]; lea rdx, [rsp + PATH_MAX + 512 + 8]; call ds_append_entry
.Lpvld_pop_next:
    pop r8
.Lpvld_next:
    lea rbx, [r8 + 1]; jmp .Lpvld_line
.Lpvld_sort:
    mov rdi, r12; call DirModel_sort
    mov rdi, r14; call mem_free; xor eax, eax; jmp .Lpvld_ret
.Lpvld_free_err:
    mov rdi, r14; call mem_free
.Lpvld_err:
    mov eax, -1
.Lpvld_ret:
    add rsp, PATH_MAX + 512 + FileStat._size + 32; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_vfs_parent_uri(const char *uri, char *out, int cap) -> 1 has parent, 0 exit VFS
pkg_vfs_parent_uri:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    mov rdi, r12; mov rsi, rbx; call str_copy
    mov rdi, r12; xor ecx, ecx
.Lpvp_find:
    mov al, [rdi + rcx]; test al, al; jz .Lpvp_exit
    cmp al, ':'; jne .Lpvp_fn
    cmp word ptr [rdi + rcx + 1], 0x2F2F; je .Lpvp_got_sch
.Lpvp_fn:
    inc rcx; jmp .Lpvp_find
.Lpvp_got_sch:
    add rcx, 3
    cmp byte ptr [r12 + rcx], 0; je .Lpvp_exit
    mov rdx, rcx
.Lpvp_end:
    cmp byte ptr [r12 + rdx], 0; je .Lpvp_scan
    inc rdx; jmp .Lpvp_end
.Lpvp_scan:
    dec rdx
    cmp rdx, rcx; jle .Lpvp_root
    cmp byte ptr [r12 + rdx], '/'; jne .Lpvp_scan
    mov byte ptr [r12 + rdx], 0; mov eax, 1; pop r12; pop rbx; ret
.Lpvp_root:
    mov byte ptr [r12 + rcx], 0; mov eax, 1; pop r12; pop rbx; ret
.Lpvp_exit:
    xor eax, eax; pop r12; pop rbx; ret

# int pkg_vfs_read_uri(char **envp, const char *uri, char *out_tmp_path, int cap) -> 0 ok, -1 err
pkg_vfs_read_uri:
    push rbx; push r12; push r13; sub rsp, PATH_MAX + 256
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov [rsp + PATH_MAX], ecx
    mov rdi, rbx; mov rsi, r12; mov rdx, rsp; call pkg_vfs_find_by_uri
    test eax, eax; jnz .Lpvr_err
    mov rdi, rsp; lea rsi, [rip + pkvp_cmd_read]; mov rdx, r12
    lea rcx, [rip + pkvp_tmp_view]; mov r8, rbx; lea r9, [rsp + PATH_MAX + 8]
    push 200; call pkvp_exec_capture; add rsp, 8
    test eax, eax; js .Lpvr_err
    mov rdi, r13; lea rsi, [rip + pkvp_tmp_view]; mov edx, [rsp + PATH_MAX]; call str_copy
    xor eax, eax; jmp .Lpvr_ret
.Lpvr_err:
    mov eax, -1
.Lpvr_ret:
    add rsp, PATH_MAX + 256; pop r13; pop r12; pop rbx; ret
