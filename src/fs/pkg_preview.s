# src/fs/pkg_preview.s - External package previewer (preview_ext + preview_exec)
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
pkpv_manifest: .asciz "manifest.ini"
pkpv_k_pext:   .asciz "preview_ext"
pkpv_k_pexec:  .asciz "preview_exec"
pkpv_dotdot:   .asciz ".."

.section .text
.global pkg_preview_try

.extern fs_read_file_head
.extern mem_zero
.extern os_dir_next_ex
.extern os_dir_read
.extern os_poll_in
.extern path_join
.extern pkg_get_root
.extern str_cmp
.extern str_len

pkpv_trim_cp:
    cmp rdi, rsi; jae .Lpvt_r
.Lpvt_l:
    mov al, [rdi]; cmp al, ' '; je .Lpvt_la; cmp al, 9; je .Lpvt_la; jmp .Lpvt_r
.Lpvt_la:
    inc rdi; cmp rdi, rsi; jb .Lpvt_l
.Lpvt_r:
    cmp rsi, rdi; jbe .Lpvt_cp
    mov al, [rsi - 1]; cmp al, ' '; je .Lpvt_rd; cmp al, 9; je .Lpvt_rd; cmp al, 13; je .Lpvt_rd; jmp .Lpvt_cp
.Lpvt_rd:
    dec rsi; jmp .Lpvt_r
.Lpvt_cp:
    xor eax, eax; dec ecx
.Lpvt_loop:
    cmp eax, ecx; jge .Lpvt_end; cmp rdi, rsi; jae .Lpvt_end
    mov r8b, [rdi]; mov [rdx + rax], r8b; inc rdi; inc eax; jmp .Lpvt_loop
.Lpvt_end:
    mov byte ptr [rdx + rax], 0; ret

# void pkpv_parse(const char *buf, int len, char *pext64, char *pexec64)
pkpv_parse:
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 64
    mov r12, rdi; movsxd rax, esi; lea r13, [r12 + rax]
    mov r14, rdx; mov r15, rcx
    mov byte ptr [r14], 0; mov byte ptr [r15], 0
.Lpvp_line:
    cmp r12, r13; jae .Lpvp_done
    mov rbx, r12
.Lpvp_eol:
    cmp rbx, r13; jae .Lpvp_got; cmp byte ptr [rbx], 10; je .Lpvp_got; inc rbx; jmp .Lpvp_eol
.Lpvp_got:
    mov rcx, r12
.Lpvp_eq:
    cmp rcx, rbx; jae .Lpvp_next; cmp byte ptr [rcx], '='; je .Lpvp_kv; inc rcx; jmp .Lpvp_eq
.Lpvp_kv:
    push rbx; push rcx
    mov rdi, r12; mov rsi, rcx; mov rdx, rsp; add rdx, 16; mov ecx, 64; call pkpv_trim_cp
    mov rdi, rsp; add rdi, 16; lea rsi, [rip + pkpv_k_pext]; call str_cmp
    pop rcx; pop rbx
    test eax, eax; jnz .Lpvp_chk_exec
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, r14; mov ecx, 64; call pkpv_trim_cp; jmp .Lpvp_next
.Lpvp_chk_exec:
    push rbx; push rcx
    mov rdi, rsp; add rdi, 16; lea rsi, [rip + pkpv_k_pexec]; call str_cmp
    pop rcx; pop rbx
    test eax, eax; jnz .Lpvp_next
    lea rdi, [rcx + 1]; mov rsi, rbx; mov rdx, r15; mov ecx, 64; call pkpv_trim_cp
.Lpvp_next:
    lea r12, [rbx + 1]; jmp .Lpvp_line
.Lpvp_done:
    add rsp, 64; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

pkpv_match_ext_ci:
    push rbx; push r12; push r13; sub rsp, 64
    mov rbx, rdi; mov r12, rsi
.Lpvme_tok:
    mov al, [rbx]; test al, al; jz .Lpvme_no
    cmp al, ','; je .Lpvme_skip; cmp al, ' '; je .Lpvme_skip
    xor ecx, ecx
.Lpvme_cp:
    cmp ecx, 63; jge .Lpvme_chk
    mov al, [rbx]; test al, al; jz .Lpvme_chk
    cmp al, ','; je .Lpvme_chk; cmp al, ' '; je .Lpvme_chk
    mov [rsp + rcx], al; inc ecx; inc rbx; jmp .Lpvme_cp
.Lpvme_chk:
    mov byte ptr [rsp + rcx], 0; mov r13d, ecx
    mov rdi, r12; call str_len; cmp eax, r13d; jl .Lpvme_tok
    sub eax, r13d; lea r8, [r12 + rax]; xor ecx, ecx
.Lpvme_cmp:
    cmp ecx, r13d; jge .Lpvme_yes
    mov al, [r8 + rcx]; mov dl, [rsp + rcx]
    cmp al, 'A'; jb .Lpvme_a; cmp al, 'Z'; ja .Lpvme_a; add al, 32
.Lpvme_a:
    cmp dl, 'A'; jb .Lpvme_b; cmp dl, 'Z'; ja .Lpvme_b; add dl, 32
.Lpvme_b:
    cmp al, dl; jne .Lpvme_tok
    inc ecx; jmp .Lpvme_cmp
.Lpvme_skip:
    inc rbx; jmp .Lpvme_tok
.Lpvme_yes:
    mov eax, 1; add rsp, 64; pop r13; pop r12; pop rbx; ret
.Lpvme_no:
    xor eax, eax; add rsp, 64; pop r13; pop r12; pop rbx; ret

# int pkpv_exec_pipe(const char *exe, const char *filepath, char **envp, char *out_buf, int max_len)
pkpv_exec_pipe:
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 48
    mov r12, rdi; mov r13, rsi; mov [rsp + 32], rdx; mov r14, rcx; mov r15d, r8d
    mov edi, AT_FDCWD; mov rsi, r12; mov edx, 0755; xor r10d, r10d; OS_FCHMODAT
    lea rdi, [rsp + 40]; xor esi, esi; OS_PIPE2
    test rax, rax; js .Lpve_err
    OS_FORK
    test rax, rax; js .Lpve_close_both; jnz .Lpve_parent
    mov edi, [rsp + 40]; OS_CLOSE
    mov edi, [rsp + 44]; mov esi, 1; OS_DUP2
    mov edi, [rsp + 44]; OS_CLOSE
    OS_NO_NEW_PRIVS
    mov [rsp], r12; mov [rsp + 8], r13; mov qword ptr [rsp + 16], 0
    mov rdi, r12; mov rsi, rsp; mov rdx, [rsp + 32]; OS_EXECVE
    mov edi, 127; OS_EXIT
.Lpve_close_both:
    mov edi, [rsp + 40]; OS_CLOSE; mov edi, [rsp + 44]; OS_CLOSE; jmp .Lpve_err
.Lpve_parent:
    mov ebx, eax
    mov edi, [rsp + 44]; OS_CLOSE
    xor r12d, r12d
.Lpve_rd:
    cmp r12d, r15d; jge .Lpve_done
    mov edi, [rsp + 40]; mov esi, 350; call os_poll_in
    test rax, rax; jle .Lpve_kill
    mov edi, [rsp + 40]; lea rsi, [r14 + r12]; mov edx, r15d; sub edx, r12d; OS_READ
    cmp rax, -EINTR; je .Lpve_rd
    test rax, rax; jle .Lpve_done
    add r12d, eax; jmp .Lpve_rd
.Lpve_kill:
    mov edi, ebx; mov esi, 9; OS_KILL
.Lpve_done:
    mov edi, [rsp + 40]; OS_CLOSE
.Lpve_wait:
    mov edi, ebx; lea rsi, [rsp + 24]; xor edx, edx; xor r10d, r10d; OS_WAIT4
    cmp rax, -EINTR; je .Lpve_wait
    mov eax, r12d; jmp .Lpve_ret
.Lpve_err:
    mov eax, -1
.Lpve_ret:
    add rsp, 48; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_preview_try(char **envp, const char *filepath, char *out_buf, int max_len) -> bytes or -1
pkg_preview_try:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16384 + 4096 + 176
    mov [rsp + 160], rdi; mov [rsp + 168], rsi; mov r12, rdx; mov r13d, ecx
    lea rsi, [rsp + 176]; mov edx, PATH_MAX; call pkg_get_root
    mov edi, AT_FDCWD; lea rsi, [rsp + 176]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lppt_no
    mov ebx, eax
.Lppt_rd:
    mov edi, ebx; lea rsi, [rsp + 176 + PATH_MAX * 2]; mov edx, 16384; call os_dir_read
    test rax, rax; jle .Lppt_close_no
    mov [rsp], rax; mov qword ptr [rsp + 8], 0
.Lppt_ent:
    lea rdi, [rsp + 176 + PATH_MAX * 2]; mov rsi, [rsp]
    lea rdx, [rsp + 8]; lea rcx, [rsp + 16]; lea r8, [rsp + 24]
    call os_dir_next_ex
    test rax, rax; jz .Lppt_rd
    mov r15, rax
    cmp byte ptr [r15], '.'; jne .Lppt_ok_seg
    cmp byte ptr [r15 + 1], 0; je .Lppt_ent
    cmp byte ptr [r15 + 1], '.'; jne .Lppt_ok_seg
    cmp byte ptr [r15 + 2], 0; je .Lppt_ent
.Lppt_ok_seg:
    lea rdi, [rsp + 176 + PATH_MAX]; lea rsi, [rsp + 176]; mov rdx, r15; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + 176 + PATH_MAX * 2 + 16384]
    lea rsi, [rsp + 176 + PATH_MAX]; lea rdx, [rip + pkpv_manifest]; mov ecx, 4096; call path_join
    lea rdi, [rsp + 176 + PATH_MAX * 2 + 16384]
    mov rsi, rdi; mov edx, 4096; lea rcx, [rsp + 24]; call fs_read_file_head
    test rax, rax; js .Lppt_ent
    lea rdi, [rsp + 176 + PATH_MAX * 2 + 16384]; mov esi, [rsp + 24]
    lea rdx, [rsp + 32]; lea rcx, [rsp + 96]; call pkpv_parse
    cmp byte ptr [rsp + 32], 0; je .Lppt_ent
    cmp byte ptr [rsp + 96], 0; je .Lppt_ent
    lea rdi, [rsp + 32]; mov rsi, [rsp + 168]; call pkpv_match_ext_ci
    test eax, eax; jz .Lppt_ent
    lea rdi, [rsp + 176 + PATH_MAX * 2 + 16384]
    lea rsi, [rsp + 176 + PATH_MAX]; lea rdx, [rsp + 96]; mov ecx, 4096; call path_join
    mov edi, ebx; OS_CLOSE
    lea rdi, [rsp + 176 + PATH_MAX * 2 + 16384]; mov rsi, [rsp + 168]
    mov rdx, [rsp + 160]; mov rcx, r12; mov r8d, r13d; call pkpv_exec_pipe
    jmp .Lppt_ret
.Lppt_close_no:
    mov edi, ebx; OS_CLOSE
.Lppt_no:
    mov eax, -1
.Lppt_ret:
    add rsp, PATH_MAX * 2 + 16384 + 4096 + 176
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret
