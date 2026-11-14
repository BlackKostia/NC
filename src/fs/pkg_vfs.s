# src/fs/pkg_vfs.s - Out-of-process VFS provider (kind=vfs, vfs_scheme=...)
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
pkv_manifest: .asciz "manifest.ini"
pkv_k_kind:   .asciz "kind"
pkv_k_scheme: .asciz "vfs_scheme"
pkv_k_exec:   .asciz "exec"
pkv_v_vfs:    .asciz "vfs"
pkv_cmd_list: .asciz "LIST"

.section .text
.global pkg_vfs_list_stdout

.extern fs_read_file_head
.extern os_dir_next_ex
.extern os_dir_read
.extern os_poll_in
.extern path_join
.extern pkg_get_root
.extern str_cmp
.extern sys_write_all

pkv_trim_cp:
    cmp rdi, rsi; jae .Lpvt2_r
.Lpvt2_l:
    mov al, [rdi]; cmp al, ' '; je .Lpvt2_la; cmp al, 9; je .Lpvt2_la; jmp .Lpvt2_r
.Lpvt2_la:
    inc rdi; cmp rdi, rsi; jb .Lpvt2_l
.Lpvt2_r:
    cmp rsi, rdi; jbe .Lpvt2_cp
    mov al, [rsi - 1]; cmp al, ' '; je .Lpvt2_rd; cmp al, 9; je .Lpvt2_rd; cmp al, 13; je .Lpvt2_rd; jmp .Lpvt2_cp
.Lpvt2_rd:
    dec rsi; jmp .Lpvt2_r
.Lpvt2_cp:
    xor eax, eax; dec ecx
.Lpvt2_loop:
    cmp eax, ecx; jge .Lpvt2_end; cmp rdi, rsi; jae .Lpvt2_end
    mov r8b, [rdi]; mov [rdx + rax], r8b; inc rdi; inc eax; jmp .Lpvt2_loop
.Lpvt2_end:
    mov byte ptr [rdx + rax], 0; ret

# void pkv_parse(buf, len, kind32, scheme64, exec64)
pkv_parse:
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 80
    mov r12, rdi; movsxd rax, esi; lea r13, [r12 + rax]
    mov r14, rdx; mov r15, rcx; mov [rsp + 64], r8
    mov byte ptr [r14], 0; mov byte ptr [r15], 0; mov byte ptr [r8], 0
.Lpkvp_line:
    cmp r12, r13; jae .Lpkvp_done
    mov rbx, r12
.Lpkvp_eol:
    cmp rbx, r13; jae .Lpkvp_got; cmp byte ptr [rbx], 10; je .Lpkvp_got; inc rbx; jmp .Lpkvp_eol
.Lpkvp_got:
    mov rcx, r12
.Lpkvp_eq:
    cmp rcx, rbx; jae .Lpkvp_next; cmp byte ptr [rcx], '='; je .Lpkvp_kv; inc rcx; jmp .Lpkvp_eq
.Lpkvp_kv:
    push rbx; push rcx
    mov rdi, r12; mov rsi, rcx; mov rdx, rsp; add rdx, 16; mov ecx, 64; call pkv_trim_cp
    mov rdi, rsp; add rdi, 16; lea rsi, [rip + pkv_k_kind]; call str_cmp
    pop rcx; pop rbx
    test eax, eax; jnz .Lpkvp_sch
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, r14; mov ecx, 32; call pkv_trim_cp; jmp .Lpkvp_next
.Lpkvp_sch:
    push rbx; push rcx
    mov rdi, rsp; add rdi, 16; lea rsi, [rip + pkv_k_scheme]; call str_cmp
    pop rcx; pop rbx
    test eax, eax; jnz .Lpkvp_ex
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, r15; mov ecx, 64; call pkv_trim_cp; jmp .Lpkvp_next
.Lpkvp_ex:
    push rbx; push rcx
    mov rdi, rsp; add rdi, 16; lea rsi, [rip + pkv_k_exec]; call str_cmp
    pop rcx; pop rbx
    test eax, eax; jnz .Lpkvp_next
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, [rsp + 64]; mov ecx, 64; call pkv_trim_cp
.Lpkvp_next:
    lea r12, [rbx + 1]; jmp .Lpkvp_line
.Lpkvp_done:
    add rsp, 80; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

pkv_exec_list:
    # rdi=exe, rsi=uri, rdx=envp -> 0 ok, -1 err
    push rbx; push r12; push r13; sub rsp, 4160
    mov r12, rdi; mov r13, rsi; mov [rsp + 48], rdx
    mov edi, AT_FDCWD; mov rsi, r12; mov edx, 0755; xor r10d, r10d; OS_FCHMODAT
    lea rdi, [rsp + 56]; xor esi, esi; OS_PIPE2
    test rax, rax; js .Lpve2_err
    OS_FORK
    test rax, rax; js .Lpve2_cl; jnz .Lpve2_par
    mov edi, [rsp + 56]; OS_CLOSE
    mov edi, [rsp + 60]; mov esi, 1; OS_DUP2
    mov edi, [rsp + 60]; OS_CLOSE
    mov [rsp], r12
    lea rax, [rip + pkv_cmd_list]; mov [rsp + 8], rax
    mov [rsp + 16], r13; mov qword ptr [rsp + 24], 0
    mov rdi, r12; mov rsi, rsp; mov rdx, [rsp + 48]; OS_EXECVE
    mov edi, 127; OS_EXIT
.Lpve2_cl:
    mov edi, [rsp + 56]; OS_CLOSE; mov edi, [rsp + 60]; OS_CLOSE; jmp .Lpve2_err
.Lpve2_par:
    mov ebx, eax; mov edi, [rsp + 60]; OS_CLOSE
.Lpve2_rd:
    mov edi, [rsp + 56]; mov esi, 1000; call os_poll_in
    test rax, rax; jle .Lpve2_done
    mov edi, [rsp + 56]; lea rsi, [rsp + 64]; mov edx, 4096; OS_READ
    cmp rax, -EINTR; je .Lpve2_rd
    test rax, rax; jle .Lpve2_done
    mov rdx, rax; lea rsi, [rsp + 64]; mov edi, STDOUT_FD; call sys_write_all
    jmp .Lpve2_rd
.Lpve2_done:
    mov edi, [rsp + 56]; OS_CLOSE
    mov edi, ebx; lea rsi, [rsp + 40]; xor edx, edx; xor r10d, r10d; OS_WAIT4
    xor eax, eax; jmp .Lpve2_ret
.Lpve2_err:
    mov eax, -1
.Lpve2_ret:
    add rsp, 4160; pop r13; pop r12; pop rbx; ret

# int pkg_vfs_list_stdout(char **envp, const char *uri) -> 0 ok, -1 err
pkg_vfs_list_stdout:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16384 + 4096 + 256
    mov [rsp + 224], rdi; mov [rsp + 232], rsi
    # Extract scheme before "://"
    xor ecx, ecx
.Lpvl_sch:
    cmp ecx, 63; jge .Lpvl_err
    mov al, [rsi + rcx]; test al, al; jz .Lpvl_err
    cmp al, ':'; je .Lpvl_sch_end
    mov [rsp + 160 + rcx], al; inc ecx; jmp .Lpvl_sch
.Lpvl_sch_end:
    mov byte ptr [rsp + 160 + rcx], 0
    mov rdi, [rsp + 224]; lea rsi, [rsp + 256]; mov edx, PATH_MAX; call pkg_get_root
    mov edi, AT_FDCWD; lea rsi, [rsp + 256]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lpvl_err
    mov ebx, eax
.Lpvl_rd:
    mov edi, ebx; lea rsi, [rsp + 256 + PATH_MAX * 2]; mov edx, 16384; call os_dir_read
    test rax, rax; jle .Lpvl_cl_err
    mov [rsp], rax; mov qword ptr [rsp + 8], 0
.Lpvl_ent:
    lea rdi, [rsp + 256 + PATH_MAX * 2]; mov rsi, [rsp]
    lea rdx, [rsp + 8]; lea rcx, [rsp + 16]; lea r8, [rsp + 24]
    call os_dir_next_ex
    test rax, rax; jz .Lpvl_rd
    mov r15, rax
    cmp byte ptr [r15], '.'; je .Lpvl_ent
    lea rdi, [rsp + 256 + PATH_MAX]; lea rsi, [rsp + 256]; mov rdx, r15; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + 256 + PATH_MAX * 2 + 16384]
    lea rsi, [rsp + 256 + PATH_MAX]; lea rdx, [rip + pkv_manifest]; mov ecx, 4096; call path_join
    lea rdi, [rsp + 256 + PATH_MAX * 2 + 16384]
    mov rsi, rdi; mov edx, 4096; lea rcx, [rsp + 24]; call fs_read_file_head
    test rax, rax; js .Lpvl_ent
    lea rdi, [rsp + 256 + PATH_MAX * 2 + 16384]; mov esi, [rsp + 24]
    lea rdx, [rsp + 32]; lea rcx, [rsp + 64]; lea r8, [rsp + 128]; call pkv_parse
    lea rdi, [rsp + 32]; lea rsi, [rip + pkv_v_vfs]; call str_cmp
    test eax, eax; jnz .Lpvl_ent
    lea rdi, [rsp + 64]; lea rsi, [rsp + 160]; call str_cmp
    test eax, eax; jnz .Lpvl_ent
    cmp byte ptr [rsp + 128], 0; je .Lpvl_ent
    lea rdi, [rsp + 256 + PATH_MAX * 2 + 16384]
    lea rsi, [rsp + 256 + PATH_MAX]; lea rdx, [rsp + 128]; mov ecx, 4096; call path_join
    mov edi, ebx; OS_CLOSE
    lea rdi, [rsp + 256 + PATH_MAX * 2 + 16384]; mov rsi, [rsp + 232]
    mov rdx, [rsp + 224]; call pkv_exec_list
    jmp .Lpvl_ret
.Lpvl_cl_err:
    mov edi, ebx; OS_CLOSE
.Lpvl_err:
    mov eax, -1
.Lpvl_ret:
    add rsp, PATH_MAX * 2 + 16384 + 4096 + 256
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret
