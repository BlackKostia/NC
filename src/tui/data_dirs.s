# Runtime data directories: finds every "*<ext>" file of one DataSpec kind (keyboard layouts,
# interface language packs, ...) so such data is added without rebuilding. Search path:
#   $<env>                    ':'-separated directories; when set, replaces everything below
#   $XDG_CONFIG_HOME/duop/<sub>  or  ~/.config/duop/<sub>
#   <binary dir>/<sub>, <binary dir>/../share/duop/<sub>   (AT_EXECFN, one symlink level)
#   /usr/local/share/duop/<sub>, /usr/share/duop/<sub>
# Directories are visited in this order, so loaders can let the first file of a kind win.

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"
.equ DD_DENTS, 4096

.section .bss
.align 8
g_ds_spec:      .space 8                  # DataSpec of the scan in progress

.section .rodata
env_xdg:        .asciz "XDG_CONFIG_HOME="
env_home:       .asciz "HOME="
mid_xdg:        .asciz "duop"
mid_home:       .asciz ".config/duop"
mid_share:      .asciz "../share/duop"
mid_none:       .asciz ""
dir_local:      .asciz "/usr/local/share/duop"
dir_usr:        .asciz "/usr/share/duop"

.section .text
.global data_dirs_scan
.global data_read_file

# void data_dirs_scan(char **envp, const DataSpec *spec) -- envp: the initial-stack array
# (the auxiliary vector follows it); spec->load(path, name) runs for every matching file
data_dirs_scan:
    push rbx
    push r12
    sub rsp, PATH_MAX * 2 + 8         # [rsp] = base dir, [rsp + PATH_MAX] = scratch
    mov rbx, rdi
    mov [rip + g_ds_spec], rsi
    mov rsi, [rsi + DataSpec.env]
    call cfg_getenv
    test rax, rax
    jz .Lds_default
    cmp byte ptr [rax], 0
    je .Lds_default
    mov rdi, rax
    call ds_scan_list
    jmp .Lds_ret
.Lds_default:
    mov rdi, rbx
    mov rsi, rsp
    call ds_user_base                 # rax = middle part ("duop" / ".config/duop") or 0
    test rax, rax
    jz .Lds_exe
    mov r12, rax
    call ds_scan_sub
.Lds_exe:
    mov rdi, rbx
    call ds_execfn
    test rax, rax
    jz .Lds_sys
    mov rdi, rax
    mov rsi, rsp
    call ds_exe_dir
    lea r12, [rip + mid_none]         # <binary dir>/<sub>
    call ds_scan_sub
    lea r12, [rip + mid_share]
    call ds_scan_sub
.Lds_sys:
    lea rdi, [rsp]
    lea rsi, [rip + dir_local]
    mov edx, PATH_MAX
    call str_copy
    lea r12, [rip + mid_none]
    call ds_scan_sub
    lea rdi, [rsp]
    lea rsi, [rip + dir_usr]
    mov edx, PATH_MAX
    call str_copy
    call ds_scan_sub
.Lds_ret:
    add rsp, PATH_MAX * 2 + 8
    pop r12
    pop rbx
    ret

# data_dirs_scan step: scan <base [rsp]>/<r12>/<spec sub> (runs on the caller's frame)
ds_scan_sub:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16 + PATH_MAX]
    lea rsi, [rsp + 16]
    mov rdx, r12
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 16 + PATH_MAX]
    mov rsi, rdi
    mov rdx, [rip + g_ds_spec]
    mov rdx, [rdx + DataSpec.sub]
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 16 + PATH_MAX]
    call ds_scan_dir
    lea rsp, [rsp + 8]
    ret

# Internal: const char *ds_user_base(char **envp, char *out) -- out = $XDG_CONFIG_HOME or $HOME;
# returns the part to append ("duop" / ".config/duop"), or 0 when neither is set
ds_user_base:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + env_xdg]
    call cfg_getenv
    lea rdx, [rip + mid_xdg]
    test rax, rax
    jz .Lub_home
    cmp byte ptr [rax], 0
    jne .Lub_copy
.Lub_home:
    mov rdi, rbx
    lea rsi, [rip + env_home]
    call cfg_getenv
    lea rdx, [rip + mid_home]
    test rax, rax
    jz .Lub_none
    cmp byte ptr [rax], 0
    je .Lub_none
.Lub_copy:
    mov rbx, rdx
    mov rdi, r12
    mov rsi, rax
    mov edx, PATH_MAX
    call str_copy
    mov rax, rbx
    jmp .Lub_ret
.Lub_none:
    xor eax, eax
.Lub_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: const char *ds_execfn(char **envp) -- AT_EXECFN from the auxiliary vector, or 0
ds_execfn:
    xor eax, eax
    test rdi, rdi
    jz .Lef_ret
.Lef_env:
    mov rcx, [rdi]
    add rdi, 8
    test rcx, rcx
    jnz .Lef_env
.Lef_aux:
    mov rcx, [rdi]
    test rcx, rcx
    jz .Lef_ret
    add rdi, 16
    cmp rcx, OS_AT_EXECFN
    jne .Lef_aux
    mov rax, [rdi - 8]
.Lef_ret:
    ret

# Internal: void ds_exe_dir(const char *path, char *out) -- out = directory of the real binary
# (one symlink level: ~/.local/bin/duop -> ~/src/duop/duop resolves to ~/src/duop)
ds_exe_dir:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    sub rsp, PATH_MAX                 # link target
    mov edi, AT_FDCWD
    mov rsi, rbx
    mov rdx, rsp
    mov r10d, PATH_MAX - 1
    OS_READLINKAT
    mov r13, rbx                      # not a symlink: the path itself
    test rax, rax
    jle .Lxd_dir
    mov byte ptr [rsp + rax], 0
    mov r13, rsp
    cmp byte ptr [rsp], '/'
    je .Lxd_dir
    mov rdi, rbx                      # relative target: <link dir>/<target>
    mov rsi, r12
    mov edx, PATH_MAX
    call path_dirname
    mov rdi, r12
    mov rsi, r12
    mov rdx, rsp
    mov ecx, PATH_MAX
    call path_join
    mov r13, r12
.Lxd_dir:
    mov rdi, r13
    mov rsi, r12
    mov edx, PATH_MAX
    call path_dirname
    add rsp, PATH_MAX
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void ds_scan_list(const char *list) -- every directory of a ':'-separated list
ds_scan_list:
    push rbx
    push r12
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
.Lsl_seg:
    xor r12d, r12d
.Lsl_ch:
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lsl_flush
    cmp al, ':'
    je .Lsl_flush
    inc rbx
    cmp r12d, PATH_MAX - 1
    jae .Lsl_ch                       # over-long entry: truncated, then simply not found
    mov [rsp + r12], al
    inc r12d
    jmp .Lsl_ch
.Lsl_flush:
    mov byte ptr [rsp + r12], 0
    test r12d, r12d
    jz .Lsl_more
    mov rdi, rsp
    call ds_scan_dir
.Lsl_more:
    cmp byte ptr [rbx], 0
    je .Lsl_ret
    inc rbx
    jmp .Lsl_seg
.Lsl_ret:
    add rsp, PATH_MAX + 8
    pop r12
    pop rbx
    ret

# Internal: void ds_scan_dir(const char *dir) -- spec->load for each matching file of one directory
ds_scan_dir:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, DD_DENTS + PATH_MAX + 16 # [0] = dirent pos, [16] = dirents, then the file path
    mov r12, rdi
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lsd_ret
    mov r13d, eax
.Lsd_batch:
    mov edi, r13d
    lea rsi, [rsp + 16]
    mov edx, DD_DENTS
    call os_dir_read
    test rax, rax
    jle .Lsd_close
    mov r14, rax
    mov qword ptr [rsp], 0
.Lsd_ent:
    lea rdi, [rsp + 16]
    mov rsi, r14
    mov rdx, rsp
    call os_dir_next
    test rax, rax
    jz .Lsd_batch
    mov r15, rax
    mov rdi, rax
    call ds_name_match
    test eax, eax
    jz .Lsd_ent
    lea rdi, [rsp + 16 + DD_DENTS]
    mov rsi, r12
    mov rdx, r15
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 16 + DD_DENTS]
    mov rsi, r15
    mov rax, [rip + g_ds_spec]
    call [rax + DataSpec.load]
    jmp .Lsd_ent
.Lsd_close:
    mov edi, r13d
    OS_CLOSE
.Lsd_ret:
    add rsp, DD_DENTS + PATH_MAX + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int ds_name_match(const char *name) -> 1 for "<something><ext>" (not hidden)
ds_name_match:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    xor eax, eax
    cmp byte ptr [rdi], '.'
    je .Lnm_ret
    call str_len
    mov r12, rax
    mov rdi, [rip + g_ds_spec]
    mov r13, [rdi + DataSpec.ext]
    mov rdi, r13
    call str_len
    cmp r12, rax
    jbe .Lnm_no
    sub r12, rax
    lea rdi, [rbx + r12]
    mov rsi, r13
    call str_cmp
    test eax, eax
    jnz .Lnm_no
    mov eax, 1
    jmp .Lnm_ret
.Lnm_no:
    xor eax, eax
.Lnm_ret:
    pop r13
    pop r12
    pop rbx
    ret

# ssize_t data_read_file(const char *path, char *buf, size_t cap) -- up to cap - 1 bytes,
# NUL-terminated; -1 when the file cannot be opened
data_read_file:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rsi
    mov r14, rdx
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lrf_fail
    mov ebx, eax
    xor r13d, r13d
.Lrf_read:
    mov edi, ebx
    lea rsi, [r12 + r13]
    lea rdx, [r14 - 1]
    sub rdx, r13
    jbe .Lrf_done
    call sys_read_retry
    test rax, rax
    jle .Lrf_done
    add r13, rax
    jmp .Lrf_read
.Lrf_done:
    mov byte ptr [r12 + r13], 0
    mov edi, ebx
    OS_CLOSE
    mov rax, r13
    jmp .Lrf_ret
.Lrf_fail:
    mov rax, -1
.Lrf_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
