# Terminal graphics capabilities: which image protocol to use (Kitty / Sixel / quadrant or half
# blocks), the cell size in pixels (TIOCGWINSZ or the CSI 16 t reply) and a filter that removes
# terminal replies (DA1 "CSI ? ... c", "CSI 6 ; h ; w t") from the input stream before key parsing.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
env_img_mode:  .asciz "DUOP_IMG_MODE"
env_kitty_win: .asciz "KITTY_WINDOW_ID"
env_term:      .asciz "TERM"
env_term_prog: .asciz "TERM_PROGRAM"
str_kitty:     .asciz "kitty"
str_sixel:     .asciz "sixel"
str_half:      .asciz "halfblock"
str_wezterm:   .asciz "wezterm"
str_ghostty:   .asciz "ghostty"
seq_query:     .ascii "\x1b[c\x1b[16t"
.equ SEQ_QUERY_LEN, 8

.section .bss
.align 4
g_ic_proto:   .space 4
g_ic_forced:  .space 4         # protocol chosen by DUOP_IMG_MODE / environment (DA1 cannot change it)
g_ic_cw:      .space 4         # cell size in pixels (0 = unknown)
g_ic_ch:      .space 4
g_ic_rcw:     .space 4         # cell size from the CSI 16 t reply
g_ic_rch:     .space 4
g_ic_changed: .space 4

.section .text
.global term_caps_init
.global term_caps_query
.global term_caps_refresh
.global term_caps_filter
.global term_img_proto
.global term_cell_px
.global term_caps_changed

# void term_caps_init(char **envp)
term_caps_init:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov dword ptr [rip + g_ic_proto], IMG_PROTO_QUAD
    lea rsi, [rip + env_img_mode]
    call env_getenv
    test rax, rax
    jz .Lci_env
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + str_half]
    mov ecx, IMG_PROTO_HALF
    call ci_match
    jz .Lci_force
    mov rdi, r12
    lea rsi, [rip + str_sixel]
    mov ecx, IMG_PROTO_SIXEL
    call ci_match
    jz .Lci_force
    mov rdi, r12
    lea rsi, [rip + str_kitty]
    mov ecx, IMG_PROTO_KITTY
    call ci_match
    jz .Lci_force
    mov ecx, IMG_PROTO_QUAD           # any other value: plain blocks, no detection
    jmp .Lci_force
.Lci_env:
    mov rdi, rbx
    call ci_kitty_env
    test eax, eax
    jz .Lci_ret
    mov ecx, IMG_PROTO_KITTY
.Lci_force:
    mov [rip + g_ic_proto], ecx
    mov dword ptr [rip + g_ic_forced], 1
.Lci_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: ZF = 1 when str_casecmp(rdi, rsi) == 0 (preserves ecx)
ci_match:
    push rcx
    call str_casecmp
    pop rcx
    test eax, eax
    ret

# Internal: int ci_kitty_env(char **envp) -- Kitty, WezTerm or Ghostty
ci_kitty_env:
    push rbx
    mov rbx, rdi
    lea rsi, [rip + env_kitty_win]
    call env_getenv
    test rax, rax
    jnz .Lke_yes
    mov rdi, rbx
    lea rsi, [rip + env_term]
    lea rdx, [rip + str_kitty]
    call ci_env_has
    jnz .Lke_yes
    mov rdi, rbx
    lea rsi, [rip + env_term_prog]
    lea rdx, [rip + str_wezterm]
    call ci_env_has
    jnz .Lke_yes
    mov rdi, rbx
    lea rsi, [rip + env_term_prog]
    lea rdx, [rip + str_ghostty]
    call ci_env_has
    jnz .Lke_yes
    xor eax, eax
    pop rbx
    ret
.Lke_yes:
    mov eax, 1
    pop rbx
    ret

# Internal: ZF = 0 when env var rsi contains rdx (case-insensitive)
ci_env_has:
    push rbx
    mov rbx, rdx
    call env_getenv
    test rax, rax
    jz .Leh_ret
    mov rdi, rax
    mov rsi, rbx
    call str_contains_ci
    test eax, eax
.Leh_ret:
    pop rbx
    ret

# void term_caps_query(void) -- ask for DA1 (Sixel support) and the cell size in pixels
term_caps_query:
    sub rsp, 8
    mov edi, STDOUT_FD
    lea rsi, [rip + seq_query]
    mov edx, SEQ_QUERY_LEN
    call sys_write_all
    add rsp, 8
    ret

# void term_caps_refresh(int cols, int rows) -- cell pixels from TIOCGWINSZ, else the CSI reply
term_caps_refresh:
    push rbx
    push r12
    sub rsp, 24
    mov ebx, edi
    mov r12d, esi
    lea rdi, [rsp]
    lea rsi, [rsp + 4]
    call os_get_winsize_px
    mov eax, [rip + g_ic_rcw]
    mov edx, [rip + g_ic_rch]
    mov ecx, [rsp]
    test ecx, ecx
    jz .Lcr_set
    cmp dword ptr [rsp + 4], 0
    je .Lcr_set
    test ebx, ebx
    jz .Lcr_set
    test r12d, r12d
    jz .Lcr_set
    mov eax, ecx
    xor edx, edx
    div ebx
    mov ecx, eax                      # cell w
    mov eax, [rsp + 4]
    xor edx, edx
    div r12d
    mov edx, eax                      # cell h
    mov eax, ecx
.Lcr_set:
    cmp eax, [rip + g_ic_cw]
    jne 1f
    cmp edx, [rip + g_ic_ch]
    je .Lcr_ret
1:  mov [rip + g_ic_cw], eax
    mov [rip + g_ic_ch], edx
    mov dword ptr [rip + g_ic_changed], 1
.Lcr_ret:
    add rsp, 24
    pop r12
    pop rbx
    ret

# int term_img_proto(void)
term_img_proto:
    mov eax, [rip + g_ic_proto]
    ret

# (int w, int h) term_cell_px(void) -> eax = cell width, edx = cell height in pixels (0 = unknown)
term_cell_px:
    mov eax, [rip + g_ic_cw]
    mov edx, [rip + g_ic_ch]
    ret

# int term_caps_changed(void) -> 1 once after the protocol or cell size changed
term_caps_changed:
    xor eax, eax
    xchg eax, [rip + g_ic_changed]
    ret

# int term_caps_filter(uint8_t *buf, int from, int len) -> bytes removed from buf[from..len)
term_caps_filter:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi                     # i
    mov r13d, edx                     # len
    xor r14d, r14d                    # removed
.Lcf_scan:
    lea eax, [r12d + 2]
    cmp eax, r13d
    jge .Lcf_done
    cmp byte ptr [rbx + r12], 0x1B
    jne .Lcf_next
    cmp byte ptr [rbx + r12 + 1], '['
    jne .Lcf_next
    lea rdi, [rbx + r12 + 2]
    lea rsi, [rbx + r13]
    call cf_reply                     # eax = reply length after "ESC [" (0 = not a reply)
    test eax, eax
    jz .Lcf_next
    add eax, 2
    add r14d, eax
    lea rsi, [rbx + r12]
    add rsi, rax
    mov rdi, rbx
    add rdi, r12
    mov edx, r13d
    sub edx, r12d
    sub edx, eax
    sub r13d, eax
    call mem_move                     # splice the reply out
    jmp .Lcf_scan
.Lcf_next:
    inc r12d
    jmp .Lcf_scan
.Lcf_done:
    mov eax, r14d
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int cf_reply(const uint8_t *p /*after ESC [*/, const uint8_t *end) -> consumed bytes
cf_reply:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor ebx, ebx                      # params seen
    xor r13d, r13d                    # flags: 1 = '?', 2 = param 4 present
    cmp byte ptr [rdi], '?'
    jne 1f
    or r13d, 1
    inc rdi
1:  sub rsp, 32                       # params[3]
    mov qword ptr [rsp], 0
    mov dword ptr [rsp + 8], 0
.Lrp_param:
    cmp rdi, rsi
    jae .Lrp_no
    call parse_uint
    cmp eax, 4
    jne 2f
    or r13d, 2
2:  cmp ebx, 3
    jae 3f
    mov [rsp + rbx * 4], eax
3:  inc ebx
    cmp rdi, rsi
    jae .Lrp_no
    movzx ecx, byte ptr [rdi]
    inc rdi
    cmp ecx, ';'
    je .Lrp_param
    cmp ecx, 'c'
    je .Lrp_da1
    cmp ecx, 't'
    je .Lrp_t
.Lrp_no:
    xor eax, eax
    jmp .Lrp_ret
.Lrp_da1:
    test r13d, 1
    jz .Lrp_no
    test r13d, 2
    jz .Lrp_len
    cmp dword ptr [rip + g_ic_forced], 0
    jne .Lrp_len
    cmp dword ptr [rip + g_ic_proto], IMG_PROTO_SIXEL
    je .Lrp_len
    mov dword ptr [rip + g_ic_proto], IMG_PROTO_SIXEL
    mov dword ptr [rip + g_ic_changed], 1
    jmp .Lrp_len
.Lrp_t:
    test r13d, 1
    jnz .Lrp_no
    cmp dword ptr [rsp], 6            # CSI 6 ; height ; width t
    jne .Lrp_len
    mov eax, [rsp + 4]
    mov [rip + g_ic_rch], eax
    mov eax, [rsp + 8]
    mov [rip + g_ic_rcw], eax
    cmp dword ptr [rip + g_ic_cw], 0
    jne .Lrp_len
    mov [rip + g_ic_cw], eax          # no TIOCGWINSZ pixels: use the reply
    mov eax, [rsp + 4]
    mov [rip + g_ic_ch], eax
    mov dword ptr [rip + g_ic_changed], 1
.Lrp_len:
    mov rax, rdi
    sub rax, r12
.Lrp_ret:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret
