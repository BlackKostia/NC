# Keyboard layouts as data: every "*.layout" file on the search path is loaded at startup into the
# kbd_map.s table, so hotkeys work in any layout and new layouts need no rebuild. Search path:
#   $DUOP_LAYOUTS            ':'-separated directories; when set, replaces everything below
#   $XDG_CONFIG_HOME/duop/layouts  or  ~/.config/duop/layouts
#   <binary dir>/layouts, <binary dir>/../share/duop/layouts   (AT_EXECFN, one symlink level)
#   /usr/local/share/duop/layouts, /usr/share/duop/layouts
# Earlier directories win when two files map the same character.

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.equ KL_DENTS, 4096

.section .rodata
env_layouts:    .asciz "DUOP_LAYOUTS="
env_xdg:        .asciz "XDG_CONFIG_HOME="
env_home:       .asciz "HOME="
rel_xdg:        .asciz "duop/layouts"
rel_home:       .asciz ".config/duop/layouts"
rel_exe:        .asciz "layouts"
rel_share:      .asciz "../share/duop/layouts"
dir_local:      .asciz "/usr/local/share/duop/layouts"
dir_usr:        .asciz "/usr/share/duop/layouts"
ext_layout:     .asciz ".layout"

.section .text
.global kbd_layout_load

# void kbd_layout_load(char **envp) -- the initial-stack envp (the auxiliary vector follows it)
kbd_layout_load:
    push rbx
    push r12
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    call kbd_map_reset
    mov rdi, rbx
    lea rsi, [rip + env_layouts]
    call cfg_getenv
    test rax, rax
    jz .Lkl_default
    cmp byte ptr [rax], 0
    je .Lkl_default
    mov rdi, rax
    call kl_scan_list
    jmp .Lkl_ret
.Lkl_default:
    mov rdi, rbx
    mov rsi, rsp
    call kl_user_dir
    test eax, eax
    jz .Lkl_exe
    mov rdi, rsp
    call kl_scan_dir
.Lkl_exe:
    mov rdi, rbx
    call kl_exe_dirs
    lea rdi, [rip + dir_local]
    call kl_scan_dir
    lea rdi, [rip + dir_usr]
    call kl_scan_dir
.Lkl_ret:
    add rsp, PATH_MAX + 8
    pop r12
    pop rbx
    ret

# Internal: int kl_user_dir(char **envp, char *out) -> 1 when out holds the user layout directory
kl_user_dir:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + env_xdg]
    call cfg_getenv
    lea rdx, [rip + rel_xdg]
    test rax, rax
    jz .Lud_home
    cmp byte ptr [rax], 0
    jne .Lud_join
.Lud_home:
    mov rdi, rbx
    lea rsi, [rip + env_home]
    call cfg_getenv
    lea rdx, [rip + rel_home]
    test rax, rax
    jz .Lud_none
    cmp byte ptr [rax], 0
    je .Lud_none
.Lud_join:
    mov rdi, r12
    mov rsi, rax
    mov ecx, PATH_MAX
    call path_join
    mov eax, 1
    jmp .Lud_ret
.Lud_none:
    xor eax, eax
.Lud_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: void kl_exe_dirs(char **envp) -- layouts/ and ../share/duop/layouts beside the binary
kl_exe_dirs:
    push rbx
    sub rsp, PATH_MAX * 2             # [rsp] = binary dir, [rsp + PATH_MAX] = joined path
    call kl_execfn
    test rax, rax
    jz .Led_ret
    mov rdi, rax
    mov rsi, rsp
    call kl_exe_resolve
    lea rbx, [rip + rel_exe]
    call kl_scan_rel
    lea rbx, [rip + rel_share]
    call kl_scan_rel
.Led_ret:
    add rsp, PATH_MAX * 2
    pop rbx
    ret

# Internal: kl_exe_dirs step -- scan <binary dir>/<rbx> (runs on the caller's frame)
kl_scan_rel:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16 + PATH_MAX]
    lea rsi, [rsp + 16]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 16 + PATH_MAX]
    call kl_scan_dir
    lea rsp, [rsp + 8]
    ret

# Internal: const char *kl_execfn(char **envp) -- AT_EXECFN from the auxiliary vector, or 0
kl_execfn:
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

# Internal: void kl_exe_resolve(const char *path, char *out) -- out = directory of the real binary
# (one symlink level: ~/.local/bin/duop -> ~/src/duop/duop finds ~/src/duop/layouts)
kl_exe_resolve:
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
    jle .Ler_dir
    mov byte ptr [rsp + rax], 0
    mov r13, rsp
    cmp byte ptr [rsp], '/'
    je .Ler_dir
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
.Ler_dir:
    mov rdi, r13
    mov rsi, r12
    mov edx, PATH_MAX
    call path_dirname
    add rsp, PATH_MAX
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void kl_scan_list(const char *list) -- every directory of a ':'-separated list
kl_scan_list:
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
    call kl_scan_dir
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

# Internal: void kl_scan_dir(const char *dir) -- load every "*.layout" file of one directory
kl_scan_dir:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, KL_DENTS + PATH_MAX + 16 # [0] = dirent pos, [16] = dirents, then the file path
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
    mov edx, KL_DENTS
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
    call kl_is_layout
    test eax, eax
    jz .Lsd_ent
    lea rdi, [rsp + 16 + KL_DENTS]
    mov rsi, r12
    mov rdx, r15
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 16 + KL_DENTS]
    call kl_load_file
    jmp .Lsd_ent
.Lsd_close:
    mov edi, r13d
    OS_CLOSE
.Lsd_ret:
    add rsp, KL_DENTS + PATH_MAX + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int kl_is_layout(const char *name) -> 1 for "<something>.layout" (not hidden)
kl_is_layout:
    push rbx
    mov rbx, rdi
    xor eax, eax
    cmp byte ptr [rdi], '.'
    je .Lil_ret
    call str_len
    cmp rax, 7
    jbe .Lil_no
    lea rdi, [rbx + rax - 7]
    lea rsi, [rip + ext_layout]
    call str_cmp
    test eax, eax
    jnz .Lil_no
    mov eax, 1
    jmp .Lil_ret
.Lil_no:
    xor eax, eax
.Lil_ret:
    pop rbx
    ret

# Internal: void kl_load_file(const char *path) -- read up to KBD_FILE_MAX - 1 bytes and parse them
kl_load_file:
    push rbx
    push r12
    push r13
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Llf_ret
    mov ebx, eax
    mov edi, KBD_FILE_MAX
    call mem_alloc
    test rax, rax
    jz .Llf_close
    mov r12, rax
    xor r13d, r13d
.Llf_read:
    mov edi, ebx
    lea rsi, [r12 + r13]
    mov edx, KBD_FILE_MAX - 1
    sub rdx, r13
    jz .Llf_parse
    call sys_read_retry
    test rax, rax
    jle .Llf_parse
    add r13, rax
    jmp .Llf_read
.Llf_parse:
    mov byte ptr [r12 + r13], 0
    mov rdi, r12
    call kbd_layout_parse
    mov rdi, r12
    call mem_free
.Llf_close:
    mov edi, ebx
    OS_CLOSE
.Llf_ret:
    pop r13
    pop r12
    pop rbx
    ret
