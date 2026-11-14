# src/fs/pkg_popup.s - PopupMenu package filtering (scope/ext) & {marked_file} writer
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PKGA_SIZE,     576
.equ PKGA_MENU,     128
.equ PKGA_ARGS,     192
.equ PKGA_SCOPE,    320
.equ PKGA_EXT,      512

.section .rodata
pkp_sc_dir:    .asciz "dir"
pkp_sc_file:   .asciz "file"
pkp_ph_marked: .asciz "{marked_file}"
pkp_tmp_pfx:   .asciz "/tmp/duop_marked_"
pkp_tmp_ext:   .asciz ".txt"

.section .bss
.align 8
pkp_scan_buf:  .space 16 * PKGA_SIZE
pkp_cache:     .space 8 * PKGA_SIZE
pkp_cnt:       .space 4
pkp_seq:       .space 4

.section .text
.global pkg_popup_refresh
.global pkg_popup_count
.global pkg_popup_label
.global pkg_popup_get
.global pkg_action_has_marked
.global pkg_write_marked_list

.extern DirModel_entry_name
.extern DirModel_get_entry
.extern path_join
.extern pkg_actions_scan
.extern str_casecmp
.extern str_cmp
.extern str_len
.extern sys_write_all

# int pkp_ends_with_ci(const char *s, const char *suf, int suf_len) -> 1 match, 0 no
pkp_ends_with_ci:
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13d, edx
    call str_len
    cmp eax, r13d; jl .Lpewc_no
    sub eax, r13d; add rbx, rax
    xor ecx, ecx
.Lpewc_loop:
    cmp ecx, r13d; jge .Lpewc_yes
    mov al, [rbx + rcx]; mov dl, [r12 + rcx]
    cmp al, 'A'; jb .Lpewc_a; cmp al, 'Z'; ja .Lpewc_a; add al, 32
.Lpewc_a:
    cmp dl, 'A'; jb .Lpewc_b; cmp dl, 'Z'; ja .Lpewc_b; add dl, 32
.Lpewc_b:
    cmp al, dl; jne .Lpewc_no
    inc ecx; jmp .Lpewc_loop
.Lpewc_yes:
    mov eax, 1; pop r13; pop r12; pop rbx; ret
.Lpewc_no:
    xor eax, eax; pop r13; pop r12; pop rbx; ret

# int pkp_match_ext(const char *ext_list, const char *name) -> 1 match, 0 no
pkp_match_ext:
    push rbx; push r12; push r13; sub rsp, 64
    mov rbx, rdi; mov r12, rsi
    cmp byte ptr [rbx], 0; je .Lpme_yes
    test r12, r12; jz .Lpme_no
.Lpme_tok:
    mov al, [rbx]; test al, al; jz .Lpme_no
    cmp al, ','; je .Lpme_skip
    cmp al, ' '; je .Lpme_skip
    xor ecx, ecx
.Lpme_cp:
    cmp ecx, 63; jge .Lpme_chk
    mov al, [rbx]; test al, al; jz .Lpme_chk
    cmp al, ','; je .Lpme_chk
    cmp al, ' '; je .Lpme_chk
    mov [rsp + rcx], al; inc ecx; inc rbx; jmp .Lpme_cp
.Lpme_chk:
    mov byte ptr [rsp + rcx], 0
    mov rdi, r12; mov rsi, rsp; mov edx, ecx; call pkp_ends_with_ci
    test eax, eax; jnz .Lpme_yes
    jmp .Lpme_tok
.Lpme_skip:
    inc rbx; jmp .Lpme_tok
.Lpme_yes:
    mov eax, 1; add rsp, 64; pop r13; pop r12; pop rbx; ret
.Lpme_no:
    xor eax, eax; add rsp, 64; pop r13; pop r12; pop rbx; ret

# int pkp_match_entry(PkgAction *act, int is_dir, const char *name) -> 1 match, 0 no
pkp_match_entry:
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12d, esi; mov r13, rdx
    cmp byte ptr [rbx + PKGA_MENU], 0; je .Lpmen_no
    lea rdi, [rbx + PKGA_SCOPE]
    cmp byte ptr [rdi], 0; je .Lpmen_ext
    lea rsi, [rip + pkp_sc_dir]; call str_cmp
    test eax, eax; jnz .Lpmen_chk_file
    test r12d, r12d; jz .Lpmen_no
    jmp .Lpmen_ext
.Lpmen_chk_file:
    lea rdi, [rbx + PKGA_SCOPE]; lea rsi, [rip + pkp_sc_file]; call str_cmp
    test eax, eax; jnz .Lpmen_ext
    test r12d, r12d; jnz .Lpmen_no
.Lpmen_ext:
    lea rdi, [rbx + PKGA_EXT]
    cmp byte ptr [rdi], 0; je .Lpmen_yes
    test r12d, r12d; jnz .Lpmen_no
    mov rsi, r13; call pkp_match_ext
    test eax, eax; jz .Lpmen_no
.Lpmen_yes:
    mov eax, 1; pop r13; pop r12; pop rbx; ret
.Lpmen_no:
    xor eax, eax; pop r13; pop r12; pop rbx; ret

# int pkg_popup_refresh(char **envp, int is_dir, const char *entry_name) -> count
pkg_popup_refresh:
    push rbx; push r12; push r13; push r14; push r15
    mov r12d, esi; mov r13, rdx
    lea rsi, [rip + pkp_scan_buf]; mov edx, 16; call pkg_actions_scan
    mov ebx, eax; xor r14d, r14d; xor r15d, r15d
.Lppr_loop:
    cmp r14d, ebx; jge .Lppr_done
    cmp r15d, 8; jge .Lppr_done
    imul rax, r14, PKGA_SIZE; lea rdi, [rip + pkp_scan_buf]; add rdi, rax
    mov esi, r12d; mov rdx, r13; call pkp_match_entry
    test eax, eax; jz .Lppr_next
    imul rsi, r14, PKGA_SIZE; lea r8, [rip + pkp_scan_buf]; add rsi, r8
    imul rdi, r15, PKGA_SIZE; lea r8, [rip + pkp_cache]; add rdi, r8
    mov ecx, PKGA_SIZE / 8; rep movsq
    inc r15d
.Lppr_next:
    inc r14d; jmp .Lppr_loop
.Lppr_done:
    mov [rip + pkp_cnt], r15d
    mov eax, r15d
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

pkg_popup_count:
    mov eax, [rip + pkp_cnt]; ret

pkg_popup_label:
    call pkg_popup_get
    test rax, rax; jz .Lppl_ret
    add rax, PKGA_MENU
.Lppl_ret:
    ret

pkg_popup_get:
    test edi, edi; js .Lppg_null
    cmp edi, [rip + pkp_cnt]; jge .Lppg_null
    imul rax, rdi, PKGA_SIZE; lea rcx, [rip + pkp_cache]; add rax, rcx; ret
.Lppg_null:
    xor eax, eax; ret

# int pkg_action_has_marked(PkgAction *act) -> 1 yes, 0 no
pkg_action_has_marked:
    lea rdi, [rdi + PKGA_ARGS]
    lea rsi, [rip + pkp_ph_marked]
.Lpahm_l:
    cmp byte ptr [rdi], 0; je .Lpahm_no
    xor ecx, ecx
.Lpahm_c:
    mov al, [rsi + rcx]; test al, al; jz .Lpahm_yes
    cmp al, [rdi + rcx]; jne .Lpahm_n
    inc ecx; jmp .Lpahm_c
.Lpahm_n:
    inc rdi; jmp .Lpahm_l
.Lpahm_yes:
    mov eax, 1; ret
.Lpahm_no:
    xor eax, eax; ret

# void pkp_build_tmp_name(char *out)
pkp_build_tmp_name:
    lea rsi, [rip + pkp_tmp_pfx]
.Lpbt_p:
    mov al, [rsi]; test al, al; jz .Lpbt_num
    mov [rdi], al; inc rdi; inc rsi; jmp .Lpbt_p
.Lpbt_num:
    mov eax, [rip + pkp_seq]; inc eax; mov [rip + pkp_seq], eax
    mov ecx, 8
.Lpbt_hex:
    rol eax, 4; mov edx, eax; and edx, 0xF
    add dl, '0'; cmp dl, '9'; jbe .Lpbt_s; add dl, 7
.Lpbt_s:
    mov [rdi], dl; inc rdi; dec ecx; jnz .Lpbt_hex
    lea rsi, [rip + pkp_tmp_ext]
.Lpbt_e:
    mov al, [rsi]; mov [rdi], al; test al, al; jz .Lpbt_done
    inc rdi; inc rsi; jmp .Lpbt_e
.Lpbt_done:
    ret

# int pkg_write_marked_list(DirModel *model, const char *fallback_path, char *out_tmp_path, int cap)
pkg_write_marked_list:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX + 16
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, r13; call pkp_build_tmp_name
    mov edi, AT_FDCWD; mov rsi, r13
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC; mov r10d, 0600; OS_OPENAT
    test rax, rax; js .Lpwml_err
    mov r14d, eax; xor r15d, r15d; xor ecx, ecx
.Lpwml_loop:
    cmp rcx, [rbx + DirModel.count]; jae .Lpwml_chk_fb
    push rcx; mov rdi, rbx; mov rsi, rcx; call DirModel_get_entry; pop rcx
    test rax, rax; jz .Lpwml_next
    test dword ptr [rax + FileEntry.flags], FE_SELECTED; jz .Lpwml_next
    push rcx; mov rdi, rbx; mov rsi, rax; call DirModel_entry_name
    lea rdi, [rsp + 8]; lea rsi, [rbx + DirModel.path]; mov rdx, rax; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + 8]; call str_len
    mov byte ptr [rsp + 8 + rax], 10; inc rax
    mov edi, r14d; lea rsi, [rsp + 8]; mov rdx, rax; call sys_write_all
    pop rcx; inc r15d
.Lpwml_next:
    inc rcx; jmp .Lpwml_loop
.Lpwml_chk_fb:
    test r15d, r15d; jnz .Lpwml_close
    test r12, r12; jz .Lpwml_close
    cmp byte ptr [r12], 0; je .Lpwml_close
    mov rdi, r12; call str_len
    mov edi, r14d; mov rsi, r12; mov rdx, rax; call sys_write_all
    mov byte ptr [rsp], 10
    mov edi, r14d; mov rsi, rsp; mov edx, 1; call sys_write_all
.Lpwml_close:
    mov edi, r14d; OS_CLOSE
    xor eax, eax; jmp .Lpwml_ret
.Lpwml_err:
    mov eax, -1
.Lpwml_ret:
    add rsp, PATH_MAX + 16; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
