# Core String, Formatting, and Path Utilities — path (split from string.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.section .text
.global path_join
.global path_dirname
.global path_basename
.global path_normalize

# int64_t path_join(char *dst, const char *dir, const char *name, size_t cap)
# rdi=dst, rsi=dir, rdx=name, rcx=cap
# Returns resulting length (>= 0) on success, or -ENAMETOOLONG on truncation/overflow.
path_join:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # dst
    mov r12, rsi              # dir
    mov r13, rdx              # name
    mov r14, rcx              # cap
    test r14, r14
    jz .Lpj_overflow

    mov rdi, r12
    call str_len
    cmp rax, r14
    jae .Lpj_overflow

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call str_copy             # rax = len(dir)

    test rax, rax
    jz .Lpj_append_name
    cmp byte ptr [rbx + rax - 1], '/'
    je .Lpj_append_name

    # Append '/'
    lea rcx, [rax + 1]
    cmp rcx, r14
    jae .Lpj_overflow
    mov byte ptr [rbx + rax], '/'
    mov byte ptr [rbx + rax + 1], 0
    mov rax, rcx

.Lpj_append_name:
    mov rsi, r13
    # Skip leading '/' in name if any
.Lpj_skip_slash:
    cmp byte ptr [rsi], '/'
    jne .Lpj_cat
    inc rsi
    jmp .Lpj_skip_slash
.Lpj_cat:
    mov r13, rsi
    mov rdi, r13
    push rax
    call str_len              # rax = len(name)
    pop rcx                   # rcx = cur_len (< r14)
    mov rdx, r14
    sub rdx, rcx              # remaining cap (>= 1)
    cmp rax, rdx
    jae .Lpj_overflow

    lea rdi, [rbx + rcx]
    mov rsi, r13
    push rcx
    push rax
    call str_copy
    pop rax
    pop rcx
    add rax, rcx              # total length (>= 0)
    jmp .Lpj_done

.Lpj_overflow:
    test r14, r14
    jz .Lpj_err
    mov byte ptr [rbx], 0
.Lpj_err:
    mov rax, -ENAMETOOLONG
.Lpj_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void path_dirname(const char *path, char *dst, size_t cap)
# rdi=path, rsi=dst, rdx=cap
path_dirname:
    push rbx
    push r12
    push r13
    mov rbx, rsi              # dst
    mov r12, rdx              # cap
    mov r13, rdi              # src

    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    call str_copy             # rax = len

    # Strip trailing slashes (except root "/")
.Lpd_strip:
    cmp rax, 1
    jbe .Lpd_find_slash
    cmp byte ptr [rbx + rax - 1], '/'
    jne .Lpd_find_slash
    dec rax
    mov byte ptr [rbx + rax], 0
    jmp .Lpd_strip

.Lpd_find_slash:
    test rax, rax
    jz .Lpd_dot
.Lpd_back:
    dec rax
    cmp byte ptr [rbx + rax], '/'
    je .Lpd_at_slash
    test rax, rax
    jnz .Lpd_back
    # No slash found -> "."
.Lpd_dot:
    cmp r12, 2
    jb .Lpd_done
    mov byte ptr [rbx], '.'
    mov byte ptr [rbx + 1], 0
    jmp .Lpd_done

.Lpd_at_slash:
    test rax, rax
    jnz .Lpd_cut
    # Slash is at index 0 -> "/"
    cmp r12, 2
    jb .Lpd_done
    mov byte ptr [rbx + 1], 0
    jmp .Lpd_done

.Lpd_cut:
    mov byte ptr [rbx + rax], 0
.Lpd_done:
    pop r13
    pop r12
    pop rbx
    ret

# const char *path_basename(const char *path)
path_basename:
    push rbx
    mov rbx, rdi
    mov esi, '/'
    call str_rchr
    test rax, rax
    jz .Lpb_ret_full
    inc rax
    cmp byte ptr [rax], 0
    jne .Lpb_done
    # Trailing slash: if only "/", return "/"
    cmp byte ptr [rbx + 1], 0
    je .Lpb_ret_full
.Lpb_done:
    pop rbx
    ret
.Lpb_ret_full:
    mov rax, rbx
    pop rbx
    ret

# size_t path_normalize(const char *base, const char *target, char *out, size_t cap)
# Lexically resolves `target` (absolute, or relative to absolute `base`) into a canonical
# absolute path: collapses "//", ".", "..", never climbs above "/", no trailing slash.
# Pure string work (no chdir/getcwd). Returns length, or 0 if it does not fit in `cap`.
path_normalize:
    call path_normalize__base
    ret

# Local: append the components of rdi to out[0..rbx); returns rax=0 or -1 on overflow
.Lpn_feed:
.Lpnf_skip:
    movzx eax, byte ptr [rdi]
    cmp eax, '/'
    jne .Lpnf_comp
    inc rdi
    jmp .Lpnf_skip
.Lpnf_comp:
    test eax, eax
    jz .Lpnf_ok
    call path_normalize__component_length
    cmp rcx, 1
    jne .Lpnf_dotdot
    cmp byte ptr [rdi], '.'
    je .Lpnf_next             # "."
.Lpnf_dotdot:
    cmp rcx, 2
    jne .Lpnf_append
    cmp word ptr [rdi], 0x2E2E
    jne .Lpnf_append
    # ".." -> drop the last component (stay at "/")
    cmp rbx, 1
    je .Lpnf_next
.Lpnf_pop:
    dec rbx
    cmp byte ptr [r14 + rbx], '/'
    jne .Lpnf_pop
    test rbx, rbx
    jnz .Lpnf_next
    mov ebx, 1
    jmp .Lpnf_next
.Lpnf_append:
    lea rax, [rbx + rcx + 2]
    cmp rax, r15
    ja .Lpnf_overflow
    call path_normalize__part3
.Lpnf_next:
    add rdi, rcx
    jmp .Lpnf_skip
.Lpnf_ok:
    xor eax, eax
    ret
.Lpnf_overflow:
    mov rax, -1
    ret

# path_normalize step: base (runs on the caller's frame)
path_normalize__base:
    lea rsp, [rsp - 8]
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi              # base
    mov r13, rsi              # target
    mov r14, rdx              # out
    mov r15, rcx              # cap
    cmp r15, 2
    jb .Lpn_fail
    mov byte ptr [r14], '/'
    mov ebx, 1                # len
    cmp byte ptr [r13], '/'
    je .Lpn_target
    mov rdi, r12
    call .Lpn_feed
    test rax, rax
    js .Lpn_fail
.Lpn_target:
    mov rdi, r13
    call .Lpn_feed
    test rax, rax
    js .Lpn_fail
    mov byte ptr [r14 + rbx], 0
    mov rax, rbx
    jmp .Lpn_ret
.Lpn_fail:
    xor eax, eax
.Lpn_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.Lpath_normalize__base_ret:
    lea rsp, [rsp + 8]
    ret

# path_normalize step: component length (runs on the caller's frame)
path_normalize__component_length:
    lea rsp, [rsp - 8]
    xor ecx, ecx              # component length
.Lpnf_len:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lpnf_have
    cmp eax, '/'
    je .Lpnf_have
    inc rcx
    jmp .Lpnf_len
.Lpnf_have:
.Lpath_normalize__component_length_ret:
    lea rsp, [rsp + 8]
    ret

# path_normalize step (runs on the caller's frame)
path_normalize__part3:
    lea rsp, [rsp - 8]
    cmp rbx, 1
    je .Lpnf_copy
    mov byte ptr [r14 + rbx], '/'
    inc rbx
.Lpnf_copy:
    xor edx, edx
.Lpnf_cloop:
    cmp rdx, rcx
    jae .Lpath_normalize__part3_ret
    mov al, [rdi + rdx]
    mov [r14 + rbx], al
    inc rbx
    inc rdx
    jmp .Lpnf_cloop
.Lpath_normalize__part3_ret:
    lea rsp, [rsp + 8]
    ret
