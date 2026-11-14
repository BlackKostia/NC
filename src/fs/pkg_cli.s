# src/fs/pkg_cli.s - CLI dispatcher for `duop pkg <list|install|remove|verify>`
.intel_syntax noprefix
.include "pal.inc"

.equ PKG_ENTRY_SZ, 296
.equ PKG_MAX_LIST, 64

.section .rodata
pkc_list:   .asciz "list"
pkc_inst:   .asciz "install"
pkc_rem:    .asciz "remove"
pkc_ver:    .asciz "verify"
pkc_sha:    .asciz "--sha256"
pkc_ok:     .asciz "OK\n"
pkc_err:    .asciz "Error\n"
pkc_sp:     .asciz "  "
pkc_nl:     .asciz "\n"
pkc_usage:  .asciz "Usage: duop pkg <list|install <path|url> [--sha256 <hex>]|remove <name>|verify <name>>\n"

.section .text
.global pkg_cli_dispatch

.extern mem_alloc
.extern mem_free
.extern pkg_install_archive
.extern pkg_list
.extern pkg_remove
.extern pkg_verify
.extern str_cmp
.extern str_len
.extern sys_write_all

pkc_puts:
    push rbx; mov rbx, rdi; call str_len
    mov edx, eax; mov rsi, rbx; mov edi, STDOUT_FD; call sys_write_all
    pop rbx; ret

pkc_do_list:
    push rbx; push r12; push r13
    mov rbx, rdi
    mov edi, PKG_MAX_LIST * PKG_ENTRY_SZ; call mem_alloc
    test rax, rax; jz .Lpdl_err
    mov r12, rax
    mov rdi, rbx; mov rsi, r12; mov edx, PKG_MAX_LIST; call pkg_list
    mov ebx, eax; xor r13d, r13d
.Lpdl_loop:
    cmp r13d, ebx; jge .Lpdl_done
    imul rcx, r13, PKG_ENTRY_SZ; add rcx, r12
    push rcx; mov rdi, rcx; call pkc_puts
    lea rdi, [rip + pkc_sp]; call pkc_puts
    pop rcx; push rcx; lea rdi, [rcx + 64]; call pkc_puts
    lea rdi, [rip + pkc_sp]; call pkc_puts
    pop rcx; push rcx; lea rdi, [rcx + 96]; call pkc_puts
    lea rdi, [rip + pkc_sp]; call pkc_puts
    pop rcx; lea rdi, [rcx + 112]; call pkc_puts
    lea rdi, [rip + pkc_nl]; call pkc_puts
    inc r13d; jmp .Lpdl_loop
.Lpdl_done:
    mov rdi, r12; call mem_free; xor eax, eax; pop r13; pop r12; pop rbx; ret
.Lpdl_err:
    mov eax, 1; pop r13; pop r12; pop rbx; ret

# int pkg_cli_dispatch(int argc, char **argv, char **envp) -> exit code
pkg_cli_dispatch:
    push rbx; push r12; push r13; push r14
    mov ebx, edi; mov r12, rsi; mov r13, rdx
    cmp ebx, 3; jl .Lpcd_usage
    mov r14, [r12 + 16]               # argv[2]
    mov rdi, r14; lea rsi, [rip + pkc_list]; call str_cmp
    test eax, eax; jz .Lpcd_list
    cmp ebx, 4; jl .Lpcd_usage
    mov rdi, r14; lea rsi, [rip + pkc_inst]; call str_cmp
    test eax, eax; jz .Lpcd_inst
    mov rdi, r14; lea rsi, [rip + pkc_rem]; call str_cmp
    test eax, eax; jz .Lpcd_rem
    mov rdi, r14; lea rsi, [rip + pkc_ver]; call str_cmp
    test eax, eax; jz .Lpcd_ver
.Lpcd_usage:
    lea rdi, [rip + pkc_usage]; call pkc_puts; mov eax, 1; jmp .Lpcd_ret
.Lpcd_list:
    mov rdi, r13; call pkc_do_list; jmp .Lpcd_ret
.Lpcd_inst:
    xor rdx, rdx
    cmp ebx, 6; jl .Lpcd_inst_go
    mov rdi, [r12 + 32]; lea rsi, [rip + pkc_sha]; call str_cmp
    test eax, eax; jnz .Lpcd_inst_go
    mov rdx, [r12 + 40]
.Lpcd_inst_go:
    mov rdi, r13; mov rsi, [r12 + 24]; call pkg_install_archive; jmp .Lpcd_res
.Lpcd_rem:
    mov rdi, r13; mov rsi, [r12 + 24]; call pkg_remove; jmp .Lpcd_res
.Lpcd_ver:
    mov rdi, r13; mov rsi, [r12 + 24]; call pkg_verify
.Lpcd_res:
    test eax, eax; jnz .Lpcd_err
    lea rdi, [rip + pkc_ok]; call pkc_puts; xor eax, eax; jmp .Lpcd_ret
.Lpcd_err:
    lea rdi, [rip + pkc_err]; call pkc_puts; mov eax, 1
.Lpcd_ret:
    pop r14; pop r13; pop r12; pop rbx; ret
