# Frozen reference oracle: the hand-written asm that src/fs/pkg_actions.c replaced (tests/test_c_pkg_actions.py diffs against it)
# src/fs/pkg_actions.s - Declarative package actions & safe argv builder
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PKGA_SIZE,     576
.equ PKGA_EXEC,     64
.equ PKGA_MENU,     128
.equ PKGA_ARGS,     192
.equ PKGA_SCOPE,    320
.equ PKGA_MODE,     336
.equ PKGA_DIR,      352
.equ PKGA_EXT,      512

.section .rodata
pka_manifest:  .asciz "manifest.ini"
pka_k_name:    .asciz "name"
pka_k_exec:    .asciz "exec"
pka_k_menu:    .asciz "menu"
pka_k_args:    .asciz "args"
pka_k_scope:   .asciz "scope"
pka_k_mode:    .asciz "mode"
pka_k_ext:     .asciz "ext"
pka_ph_dir:    .asciz "{dir}"
pka_ph_other:  .asciz "{other_dir}"
pka_ph_file:   .asciz "{file}"
pka_ph_path:   .asciz "{path}"
pka_ph_marked: .asciz "{marked_file}"
pka_empty:     .asciz ""
pka_dotdot:    .asciz ".."

.section .bss
.align 8
pka_menu_cache: .space 16 * PKGA_SIZE
pka_menu_cnt:   .space 4

.section .text
.global pkg_action_parse
.global pkg_actions_scan
.global pkg_action_find
.global pkg_action_build_argv
.global pkg_menu_refresh
.global pkg_menu_count
.global pkg_menu_get

.extern fs_read_file_head
.extern mem_zero
.extern os_dir_next_ex
.extern os_dir_read
.extern path_join
.extern pkm_safe_relpath
.extern pkg_get_root
.extern str_cmp
.extern str_copy
.extern str_len

# void pka_trim_copy(const char *s, const char *e, char *dst, int cap)
pka_trim_copy:
    cmp rdi, rsi; jae .Lptc_trim_r
.Lptc_l:
    mov al, [rdi]
    cmp al, ' '; je .Lptc_l_adv
    cmp al, 9; je .Lptc_l_adv
    jmp .Lptc_trim_r
.Lptc_l_adv:
    inc rdi; cmp rdi, rsi; jb .Lptc_l
.Lptc_trim_r:
    cmp rsi, rdi; jbe .Lptc_cp
    mov al, [rsi - 1]
    cmp al, ' '; je .Lptc_r_dec
    cmp al, 9; je .Lptc_r_dec
    cmp al, 13; je .Lptc_r_dec
    jmp .Lptc_cp
.Lptc_r_dec:
    dec rsi; jmp .Lptc_trim_r
.Lptc_cp:
    xor eax, eax; dec ecx
.Lptc_loop:
    cmp eax, ecx; jge .Lptc_end
    cmp rdi, rsi; jae .Lptc_end
    mov r8b, [rdi]; mov [rdx + rax], r8b
    inc rdi; inc eax; jmp .Lptc_loop
.Lptc_end:
    mov byte ptr [rdx + rax], 0; ret

# void pka_parse_kv(const char *key, const char *val, const char *eol, PkgAction *out)
pka_parse_kv:
    push rbx; push r12; push r13; push r14
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov r14, rcx
    lea rsi, [rip + pka_k_name]; call str_cmp
    test eax, eax; jnz .Lpkv_exec
    mov rdi, r12; mov rsi, r13; mov rdx, r14; mov ecx, 64; call pka_trim_copy; jmp .Lpkv_ret
.Lpkv_exec:
    mov rdi, rbx; lea rsi, [rip + pka_k_exec]; call str_cmp
    test eax, eax; jnz .Lpkv_menu
    mov rdi, r12; mov rsi, r13; lea rdx, [r14 + PKGA_EXEC]; mov ecx, 64; call pka_trim_copy; jmp .Lpkv_ret
.Lpkv_menu:
    mov rdi, rbx; lea rsi, [rip + pka_k_menu]; call str_cmp
    test eax, eax; jnz .Lpkv_args
    mov rdi, r12; mov rsi, r13; lea rdx, [r14 + PKGA_MENU]; mov ecx, 64; call pka_trim_copy; jmp .Lpkv_ret
.Lpkv_args:
    mov rdi, rbx; lea rsi, [rip + pka_k_args]; call str_cmp
    test eax, eax; jnz .Lpkv_scope
    mov rdi, r12; mov rsi, r13; lea rdx, [r14 + PKGA_ARGS]; mov ecx, 128; call pka_trim_copy; jmp .Lpkv_ret
.Lpkv_scope:
    mov rdi, rbx; lea rsi, [rip + pka_k_scope]; call str_cmp
    test eax, eax; jnz .Lpkv_mode
    mov rdi, r12; mov rsi, r13; lea rdx, [r14 + PKGA_SCOPE]; mov ecx, 16; call pka_trim_copy; jmp .Lpkv_ret
.Lpkv_mode:
    mov rdi, rbx; lea rsi, [rip + pka_k_mode]; call str_cmp
    test eax, eax; jnz .Lpkv_ext
    mov rdi, r12; mov rsi, r13; lea rdx, [r14 + PKGA_MODE]; mov ecx, 16; call pka_trim_copy; jmp .Lpkv_ret
.Lpkv_ext:
    mov rdi, rbx; lea rsi, [rip + pka_k_ext]; call str_cmp
    test eax, eax; jnz .Lpkv_ret
    mov rdi, r12; mov rsi, r13; lea rdx, [r14 + PKGA_EXT]; mov ecx, 64; call pka_trim_copy
.Lpkv_ret:
    pop r14; pop r13; pop r12; pop rbx; ret

# void pkg_action_parse(const char *buf, int len, PkgAction *out)
pkg_action_parse:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 72
    mov r12, rdi; movsxd rax, esi; lea r13, [r12 + rax]; mov r14, rdx
    mov rdi, r14; mov esi, PKGA_SIZE; call mem_zero
.Lpap_line:
    cmp r12, r13; jae .Lpap_done
    mov r15, r12
.Lpap_eol:
    cmp r15, r13; jae .Lpap_got
    cmp byte ptr [r15], 10; je .Lpap_got
    inc r15; jmp .Lpap_eol
.Lpap_got:
    mov rbx, r12
.Lpap_eq:
    cmp rbx, r15; jae .Lpap_next
    cmp byte ptr [rbx], '='; je .Lpap_key
    inc rbx; jmp .Lpap_eq
.Lpap_key:
    mov rdi, r12; mov rsi, rbx; mov rdx, rsp; mov ecx, 64; call pka_trim_copy
    mov rdi, rsp; lea rsi, [rbx + 1]; mov rdx, r15; mov rcx, r14; call pka_parse_kv
.Lpap_next:
    lea r12, [r15 + 1]; jmp .Lpap_line
.Lpap_done:
    add rsp, 72; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pka_safe_seg(const char *s) -> 1 safe, 0 unsafe
pka_safe_seg:
    test rdi, rdi; jz .Lpss_no
    cmp byte ptr [rdi], 0; je .Lpss_no
    lea rsi, [rip + pka_dotdot]; call str_cmp
    test eax, eax; jz .Lpss_no
.Lpss_l:
    mov al, [rdi]; test al, al; jz .Lpss_ok
    cmp al, '/'; je .Lpss_no
    inc rdi; jmp .Lpss_l
.Lpss_ok:
    mov eax, 1; ret
.Lpss_no:
    xor eax, eax; ret

# int pkg_action_find(char **envp, const char *name, PkgAction *out) -> 0 ok, -1 err
pkg_action_find:
    push rbx; push r12; push r13
    sub rsp, PATH_MAX * 2 + 4096 + 16
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, r12; call pka_safe_seg; test eax, eax; jz .Lpaf_err
    mov rdi, rbx; mov rsi, rsp; mov edx, PATH_MAX; call pkg_get_root
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; mov rdx, r12; mov ecx, PATH_MAX; call path_join
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX]; lea rdx, [rip + pka_manifest]; mov ecx, PATH_MAX; call path_join
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX * 2 + 16]; mov edx, 4096; lea rcx, [rsp + PATH_MAX * 2]
    call fs_read_file_head; test rax, rax; js .Lpaf_err
    lea rdi, [rsp + PATH_MAX * 2 + 16]; mov esi, [rsp + PATH_MAX * 2]; mov rdx, r13; call pkg_action_parse
    lea rdi, [r13 + PKGA_EXEC]; call pkm_safe_relpath; test rax, rax; jz .Lpaf_err
    lea rdi, [rsp + PATH_MAX]; call str_len; cmp rax, 160; jae .Lpaf_err
    lea rdi, [r13 + PKGA_DIR]; lea rsi, [rsp + PATH_MAX]; mov edx, 160; call str_copy
    xor eax, eax; jmp .Lpaf_ret
.Lpaf_err:
    mov eax, -1
.Lpaf_ret:
    add rsp, PATH_MAX * 2 + 4096 + 16; pop r13; pop r12; pop rbx; ret

# int pkg_actions_scan(char **envp, PkgAction *out, int max) -> count
pkg_actions_scan:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16384 + 4096 + 32
    mov r12, rsi; mov r13d, edx; xor r14d, r14d
    lea rsi, [rsp + 32]; mov edx, PATH_MAX; call pkg_get_root
    mov edi, AT_FDCWD; lea rsi, [rsp + 32]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lpas_ret
    mov ebx, eax
.Lpas_read:
    mov edi, ebx; lea rsi, [rsp + 32 + PATH_MAX * 2]; mov edx, 16384; call os_dir_read
    test rax, rax; jle .Lpas_close
    mov [rsp], rax; mov qword ptr [rsp + 8], 0
.Lpas_ent:
    cmp r14d, r13d; jge .Lpas_close
    lea rdi, [rsp + 32 + PATH_MAX * 2]; mov rsi, [rsp]
    lea rdx, [rsp + 8]; lea rcx, [rsp + 16]; lea r8, [rsp + 24]
    call os_dir_next_ex
    test rax, rax; jz .Lpas_read
    mov r15, rax
    mov rdi, r15; call pka_safe_seg; test eax, eax; jz .Lpas_ent
    lea rdi, [rsp + 32 + PATH_MAX]; lea rsi, [rsp + 32]; mov rdx, r15; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + 32 + PATH_MAX * 2 + 16384]
    lea rsi, [rsp + 32 + PATH_MAX]; lea rdx, [rip + pka_manifest]; mov ecx, 4096; call path_join
    lea rdi, [rsp + 32 + PATH_MAX * 2 + 16384]
    mov rsi, rdi; mov edx, 4096; lea rcx, [rsp + 24]
    call fs_read_file_head; test rax, rax; js .Lpas_ent
    imul rdx, r14, PKGA_SIZE; add rdx, r12
    lea rdi, [rsp + 32 + PATH_MAX * 2 + 16384]; mov esi, [rsp + 24]; call pkg_action_parse
    imul rdx, r14, PKGA_SIZE; add rdx, r12
    cmp byte ptr [rdx + PKGA_EXEC], 0; je .Lpas_ent
    lea rdi, [rdx + PKGA_DIR]; lea rsi, [rsp + 32 + PATH_MAX]; mov edx, 160; call str_copy
    inc r14d; jmp .Lpas_ent
.Lpas_close:
    mov edi, ebx; OS_CLOSE
.Lpas_ret:
    mov eax, r14d
    add rsp, PATH_MAX * 2 + 16384 + 4096 + 32
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# const char *pka_resolve_tok(const char *tok, const char **ctx) -> NULL if literal
pka_resolve_tok:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    lea rsi, [rip + pka_ph_dir]; call str_cmp; test eax, eax; jz .Lprt_0
    mov rdi, rbx; lea rsi, [rip + pka_ph_other]; call str_cmp; test eax, eax; jz .Lprt_1
    mov rdi, rbx; lea rsi, [rip + pka_ph_file]; call str_cmp; test eax, eax; jz .Lprt_2
    mov rdi, rbx; lea rsi, [rip + pka_ph_path]; call str_cmp; test eax, eax; jz .Lprt_3
    mov rdi, rbx; lea rsi, [rip + pka_ph_marked]; call str_cmp; test eax, eax; jz .Lprt_4
    xor eax, eax; pop r12; pop rbx; ret
.Lprt_0:
    mov rax, [r12 + 0]; jmp .Lprt_chk
.Lprt_1:
    mov rax, [r12 + 8]; jmp .Lprt_chk
.Lprt_2:
    mov rax, [r12 + 16]; jmp .Lprt_chk
.Lprt_3:
    mov rax, [r12 + 24]; jmp .Lprt_chk
.Lprt_4:
    mov rax, [r12 + 32]
.Lprt_chk:
    test rax, rax; jnz .Lprt_done
    lea rax, [rip + pka_empty]
.Lprt_done:
    pop r12; pop rbx; ret

# int pkg_action_build_argv(PkgAction *act, const char **ctx, char *str_buf, int buf_cap, char **argv_out, int max_args)
pkg_action_build_argv:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 32
    mov rbx, rdi; mov [rsp], rsi; mov r12, rdx; mov r13d, ecx
    mov r14, r8; mov [rsp + 8], r9d
    cmp r13d, 2; jl .Lpba_fail
    cmp r9d, 2; jl .Lpba_fail
    lea rdi, [rbx + PKGA_EXEC]; call pkm_safe_relpath
    test rax, rax; jz .Lpba_fail
    lea rsi, [rbx + PKGA_DIR]; lea rdx, [rbx + PKGA_EXEC]; mov rdi, r12; mov ecx, r13d
    call path_join # path-checked
    test rax, rax; js .Lpba_fail
    mov [r14], r12; mov r15d, 1
    inc eax
    cmp eax, r13d; jge .Lpba_done
    add r12, rax; sub r13d, eax
    lea rbx, [rbx + PKGA_ARGS]
.Lpba_skip:
    mov al, [rbx]; test al, al; jz .Lpba_done
    cmp al, ' '; je .Lpba_ws
    cmp al, 9; jne .Lpba_tok
.Lpba_ws:
    inc rbx; jmp .Lpba_skip
.Lpba_tok:
    cmp r13d, 2; jl .Lpba_done
    mov eax, [rsp + 8]; dec eax
    cmp r15d, eax; jge .Lpba_done
    xor ecx, ecx; mov edx, r13d; dec edx
.Lpba_cp:
    cmp ecx, edx; jge .Lpba_tok_end
    mov al, [rbx]; test al, al; jz .Lpba_tok_end
    cmp al, ' '; je .Lpba_tok_end
    cmp al, 9; je .Lpba_tok_end
    mov [r12 + rcx], al; inc ecx; inc rbx; jmp .Lpba_cp
.Lpba_tok_end:
    mov byte ptr [r12 + rcx], 0
    push rcx; mov rdi, r12; mov rsi, [rsp + 8]; call pka_resolve_tok; pop rcx
    test rax, rax; jnz .Lpba_ph
    mov [r14 + r15 * 8], r12; inc r15d
    inc ecx; add r12, rcx; sub r13d, ecx; jmp .Lpba_skip
.Lpba_ph:
    mov [r14 + r15 * 8], rax; inc r15d; jmp .Lpba_skip
.Lpba_done:
    mov qword ptr [r14 + r15 * 8], 0
    mov eax, r15d
    jmp .Lpba_ret
.Lpba_fail:
    mov qword ptr [r14], 0
    mov eax, -1
.Lpba_ret:
    add rsp, 32; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_menu_refresh(char **envp) -> count of menu-enabled packages
pkg_menu_refresh:
    push rbx; push r12; push r13
    lea rsi, [rip + pka_menu_cache]; mov edx, 16; call pkg_actions_scan
    mov ebx, eax; xor r12d, r12d; xor r13d, r13d
.Lpmr_loop:
    cmp r12d, ebx; jge .Lpmr_done
    imul rcx, r12, PKGA_SIZE; lea rsi, [rip + pka_menu_cache]; add rsi, rcx
    cmp byte ptr [rsi + PKGA_MENU], 0; je .Lpmr_next
    cmp r12d, r13d; je .Lpmr_keep
    imul rax, r13, PKGA_SIZE; lea rdi, [rip + pka_menu_cache]; add rdi, rax
    mov ecx, PKGA_SIZE / 8; rep movsq
.Lpmr_keep:
    inc r13d
.Lpmr_next:
    inc r12d; jmp .Lpmr_loop
.Lpmr_done:
    mov [rip + pka_menu_cnt], r13d
    mov eax, r13d
    pop r13; pop r12; pop rbx; ret

# int pkg_menu_count(void)
pkg_menu_count:
    mov eax, [rip + pka_menu_cnt]; ret

# PkgAction *pkg_menu_get(int idx) -> ptr or NULL
pkg_menu_get:
    test edi, edi; js .Lpmg_null
    cmp edi, [rip + pka_menu_cnt]; jge .Lpmg_null
    imul rax, rdi, PKGA_SIZE; lea rcx, [rip + pka_menu_cache]; add rax, rcx; ret
.Lpmg_null:
    xor eax, eax; ret
