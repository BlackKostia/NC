# Frozen reference oracle: the hand-written asm that src/core/config_load.c replaced (tests/test_c_config.py diffs against it)
# Duop Runtime Configuration (~/.config/duop/duoprc) & User Menu Expansion — config load (split from config.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"
.equ CFG_BIND_SZ,     16      # key(4), mods(4), action(4), pad(4)
.equ CFG_OPEN_SZ,     256     # ext(16), cmd(240)
.equ CFG_MENU_SZ,     256     # label(64), cmd(192)
.equ CFG_THEME,       0
.equ CFG_LANG,        4
.equ CFG_HIDDEN,      8
.equ CFG_SORT,        12
.equ CFG_BIND_CNT,    20
.equ CFG_OPEN_CNT,    24
.equ CFG_MENU_CNT,    28
.equ CFG_BINDS,       160
.equ CFG_OPENS,       672
.equ CFG_MENUS,       8864
.equ CFG_TOTAL_SZ,    15024         # + CFG_LANG_ID (config.inc)
.equ CFG_FILE_HARD,   1048576      # 1 MiB: bigger files keep their head and raise g_cfg_warn
.equ DEFAULT_MENU_COUNT, 3
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern sys_read_retry
.extern str_len
.extern str_copy
.extern str_cmp
.extern str_casecmp
.extern str_starts_with
.extern path_join

.section .bss

.align 16
g_config:          .space CFG_TOTAL_SZ
g_cfg_warn:        .space 4       # 1 when duoprc exceeded the hard size limit

.section .rodata
env_duop_cfg:      .asciz "DUOP_CONFIG="
env_xdg_cfg:       .asciz "XDG_CONFIG_HOME="
env_home:          .asciz "HOME="
rel_xdg_duoprc:    .asciz "duop/duoprc"
rel_home_duoprc:   .asciz ".config/duop/duoprc"

def_m0_lbl:        .asciz "Disk usage of current dir (du -sh)"
def_m0_cmd:        .asciz "du -sh \"%d\"; printf 'Press Enter...'; read -r _"
def_m1_lbl:        .asciz "File info (file / stat)"
def_m1_cmd:        .asciz "file \"%p\"; stat \"%p\"; printf 'Press Enter...'; read -r _"
def_m2_lbl:        .asciz "Line count (wc -l)"
def_m2_cmd:        .asciz "wc -l \"%p\"; printf 'Press Enter...'; read -r _"

.align 8
default_menu_table:
    .quad def_m0_lbl, def_m0_cmd
    .quad def_m1_lbl, def_m1_cmd
    .quad def_m2_lbl, def_m2_cmd

.section .text
.global config_load
.global config_get
.global config_lookup_bind
.global config_lookup_open
.global config_menu_count
.global config_menu_item
.global g_config
.global g_cfg_warn

# void config_load(char **envp)
config_load:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, PATH_MAX + 8
    call config_load__initialize_defaults
    # 1. Try DUOP_CONFIG
    mov rdi, rbx
    lea rsi, [rip + env_duop_cfg]
    call cfg_getenv
    test rax, rax
    jz .Lcl_try_xdg
    cmp byte ptr [rax], 0
    je .Lcl_try_xdg
    mov rsi, rax
    jmp .Lcl_open

.Lcl_try_xdg:
    mov rdi, rbx
    lea rsi, [rip + env_xdg_cfg]
    call cfg_getenv
    test rax, rax
    jz .Lcl_try_home
    cmp byte ptr [rax], 0
    je .Lcl_try_home
    call config_load__path_join
    test rax, rax
    js .Lcl_try_home
    lea rsi, [rsp]
    jmp .Lcl_open

.Lcl_try_home:
    mov rdi, rbx
    lea rsi, [rip + env_home]
    call cfg_getenv
    test rax, rax
    jz .Lcl_done
    cmp byte ptr [rax], 0
    je .Lcl_done
    call config_load__path_join_2
    test rax, rax
    js .Lcl_done
    lea rsi, [rsp]
.Lcl_open:
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_NONBLOCK | O_CLOEXEC
    xor r10d, r10d
    call config_load__buf
.Lcl_done:
    add rsp, PATH_MAX + 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# config_load step: Initialize defaults (runs on the caller's frame)
config_load__initialize_defaults:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # envp

    # Initialize defaults
    lea rdi, [rip + g_config]
    mov esi, CFG_TOTAL_SZ
    call mem_zero
    lea r12, [rip + g_config]
    mov dword ptr [r12 + CFG_THEME], -1
    mov dword ptr [r12 + CFG_LANG], -1
    mov dword ptr [r12 + CFG_HIDDEN], -1
    mov dword ptr [r12 + CFG_SORT], -1

.Lconfig_load__initialize_defaults_ret:
    lea rsp, [rsp + 8]
    ret

# config_load step: path_join (runs on the caller's frame)
config_load__path_join:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    mov rsi, rax
    lea rdx, [rip + rel_xdg_duoprc]
    mov ecx, PATH_MAX
    call path_join
    lea rsi, [rsp + 16]
.Lconfig_load__path_join_ret:
    lea rsp, [rsp + 8]
    ret

# config_load step: path_join (runs on the caller's frame)
config_load__path_join_2:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    mov rsi, rax
    lea rdx, [rip + rel_home_duoprc]
    mov ecx, PATH_MAX
    call path_join
    lea rsi, [rsp + 16]

.Lconfig_load__path_join_2_ret:
    lea rsp, [rsp + 8]
    ret

# Helper: void config_load_parse_buf(char *buf)
config_load_parse_buf:
    push rbx; sub rsp, 16             # aligned: rbx + 16 = 0 mod 16
.Lcl_line_loop:
    cmp byte ptr [rdi], 0; je .Lcl_pb_ret
    mov rbx, rdi
.Lcl_find_nl:
    movzx eax, byte ptr [rbx]; test al, al; jz .Lcl_end_line
    cmp al, '\n'; je .Lcl_end_line
    inc rbx; jmp .Lcl_find_nl
.Lcl_end_line:
    xor edx, edx
    cmp byte ptr [rbx], '\n'; sete dl
    mov byte ptr [rbx], 0
    cmp rbx, rdi; jbe 1f
    cmp byte ptr [rbx - 1], '\r'; jne 1f
    mov byte ptr [rbx - 1], 0
1:  add rbx, rdx
    mov [rsp], rbx; mov [rsp + 8], edx
    call parse_config_line
    mov rdi, [rsp]
    cmp dword ptr [rsp + 8], 0; jne .Lcl_line_loop
.Lcl_pb_ret:
    add rsp, 16; pop rbx; ret

# config_load step: buf (runs on the caller's frame)
config_load__buf:
    lea rsp, [rsp - 8]
    OS_OPENAT
    test rax, rax
    js .Lconfig_load__buf_ret
    mov r13d, eax             # fd

    sub rsp, 64
    mov edi, r13d
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lcl_stat_bad
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Lcl_stat_bad
    mov r12, [rsp + FileStat.size]
    add rsp, 64
    cmp r12, CFG_FILE_HARD
    jbe .Lcl_sized
    mov dword ptr [rip + g_cfg_warn], 1       # beyond the hard limit: the head is used, the user is told
    mov r12d, CFG_FILE_HARD
.Lcl_sized:
    lea rdi, [r12 + 1]
    call mem_alloc
    test rax, rax
    jz .Lcl_close
    mov r14, rax              # buf (exactly the file size + NUL: no silent size cap below the hard limit)

    xor ebx, ebx              # total
.Lcl_read:
    cmp rbx, r12
    jae .Lcl_parse
    mov edi, r13d
    lea rsi, [r14 + rbx]
    mov rdx, r12
    sub rdx, rbx
    call sys_read_retry
    test rax, rax
    js .Lcl_free
    jz .Lcl_parse
    add rbx, rax
    jmp .Lcl_read

.Lcl_parse:
    cmp dword ptr [rip + g_cfg_warn], 0
    je .Lcl_nul
.Lcl_trim:
    test rbx, rbx
    jz .Lcl_nul
    cmp byte ptr [r14 + rbx - 1], 10      # a cut file ends at its last complete line
    je .Lcl_nul
    dec rbx
    jmp .Lcl_trim
.Lcl_nul:
    mov byte ptr [r14 + rbx], 0
    mov rdi, r14
    call config_load_parse_buf
.Lcl_free:
    mov rdi, r14
    call mem_free
.Lcl_close:
    mov edi, r13d
    OS_CLOSE                  # fault-checked: close opened config fd on exit/error
.Lconfig_load__buf_ret:
    lea rsp, [rsp + 8]
    ret
.Lcl_stat_bad:
    add rsp, 64
    jmp .Lcl_close

# Config *config_get(void)
config_get:
    lea rax, [rip + g_config]
    ret

# int config_lookup_bind(int key, int mods) -> action_id or -1
config_lookup_bind:
    lea r8, [rip + g_config]
    mov ecx, [r8 + CFG_BIND_CNT]
    xor edx, edx
.Lclb_loop:
    cmp edx, ecx
    jae .Lclb_none
    imul rax, rdx, CFG_BIND_SZ
    lea r9, [r8 + CFG_BINDS + rax]
    cmp [r9 + 0], edi
    jne .Lclb_next
    cmp [r9 + 4], esi
    jne .Lclb_next
    mov eax, [r9 + 8]
    ret
.Lclb_next:
    inc edx
    jmp .Lclb_loop
.Lclb_none:
    mov eax, -1
    ret

# const char *config_lookup_open(const char *filename)
config_lookup_open:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    test rbx, rbx
    jz .Lclo_none
    # Find last '.' after index 0
    xor r12d, r12d
    mov rcx, 1
    cmp byte ptr [rbx], 0
    je .Lclo_none
.Lclo_dot:
    mov al, [rbx + rcx]
    test al, al
    jz .Lclo_dot_done
    cmp al, '.'
    jne .Lclo_dot_next
    lea r12, [rbx + rcx + 1]
.Lclo_dot_next:
    inc rcx
    jmp .Lclo_dot
.Lclo_dot_done:
    test r12, r12
    jz .Lclo_none
    cmp byte ptr [r12], 0
    je .Lclo_none

    lea r13, [rip + g_config]
    xor ebx, ebx
.Lclo_loop:
    cmp ebx, [r13 + CFG_OPEN_CNT]
    jae .Lclo_none
    imul rax, rbx, CFG_OPEN_SZ
    lea r8, [r13 + CFG_OPENS + rax]
    mov rdi, r12
    mov rsi, r8
    push r8
    call str_casecmp
    pop r8
    test eax, eax
    jz .Lclo_hit
    inc ebx
    jmp .Lclo_loop
.Lclo_hit:
    lea rax, [r8 + 16]
    pop r13
    pop r12
    pop rbx
    ret
.Lclo_none:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# int config_menu_count(void)
config_menu_count:
    lea rax, [rip + g_config]
    mov eax, [rax + CFG_MENU_CNT]
    test eax, eax
    jnz .Lcmc_ret
    mov eax, DEFAULT_MENU_COUNT
.Lcmc_ret:
    ret

# int config_menu_item(int idx, const char **out_label, const char **out_cmd)
config_menu_item:
    lea r8, [rip + g_config]
    mov ecx, [r8 + CFG_MENU_CNT]
    test ecx, ecx
    jz .Lcmi_def
    cmp edi, ecx
    jae .Lcmi_bad
    imul rax, rdi, CFG_MENU_SZ
    lea r8, [r8 + CFG_MENUS + rax]
    mov [rsi], r8
    lea r8, [r8 + 64]
    mov [rdx], r8
    mov eax, 1
    ret
.Lcmi_def:
    cmp edi, DEFAULT_MENU_COUNT
    jae .Lcmi_bad
    shl rdi, 4                # * 16 (2 quads)
    lea r8, [rip + default_menu_table]
    mov rax, [r8 + rdi]
    mov [rsi], rax
    mov rax, [r8 + rdi + 8]
    mov [rdx], rax
    mov eax, 1
    ret
.Lcmi_bad:
    xor eax, eax
    ret
