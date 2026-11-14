# Keyboard layouts as data: every "*.layout" file on the data path (data_dirs.s: $DUOP_LAYOUTS,
# ~/.config/duop/layouts, layouts/ beside the binary, share/duop/layouts) is loaded at startup into
# the kbd_map.s table, so hotkeys work in any layout and new layouts need no rebuild.

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"

.section .rodata
env_layouts:    .asciz "DUOP_LAYOUTS="
sub_layouts:    .asciz "layouts"
ext_layout:     .asciz ".layout"

.align 8
kbd_spec:
    .quad env_layouts, sub_layouts, ext_layout, kl_load_file

.section .text
.global kbd_layout_load

# void kbd_layout_load(char **envp) -- the initial-stack envp (the auxiliary vector follows it)
kbd_layout_load:
    push rbx
    mov rbx, rdi
    call kbd_map_reset
    mov rdi, rbx
    lea rsi, [rip + kbd_spec]
    call data_dirs_scan
    pop rbx
    ret

# Internal: void kl_load_file(const char *path, const char *name) -- parse one layout file
kl_load_file:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov edi, KBD_FILE_MAX
    call mem_alloc
    test rax, rax
    jz .Llf_ret
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, KBD_FILE_MAX
    call data_read_file
    test rax, rax
    js .Llf_free
    mov rdi, r12
    call kbd_layout_parse
.Llf_free:
    mov rdi, r12
    call mem_free
.Llf_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret
