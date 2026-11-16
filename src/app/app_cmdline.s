# src/app/app_cmdline.s - run a User Menu / open-rule command template safely
#
# Collects the marked names (or the current one) into a NUL separated list, expands the template
# with config_expand_cmd (quote-aware, all-or-nothing) into a heap buffer and hands the script to
# /bin/sh in the active pane's directory. An expansion that does not fit is reported and NEVER run.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ AC_SEL_CAP, 60000        # marked names: NUL separated, ended by an empty name
.equ AC_CMD_CAP, 120000       # expanded script; below the Linux per-argument limit (131072)
# command frame (on the caller's stack)
.equ ACF_CTX,    0            # ConfigExpandCtx: cur_name, cur_path, selection list, active dir, opposite dir
.equ ACF_SEL,    40           # heap: selection list
.equ ACF_CMD,    48           # heap: expanded command
.equ ACF_APP,    56
.equ ACF_TMPL,   64
.equ ACF_CWD,    72           # saved working directory (PATH_MAX)
.equ ACF_SIZE,   ACF_CWD + PATH_MAX + 8

.section .text
.global App_run_expanded_cmd

.extern mem_alloc
.extern mem_free
.extern config_expand_cmd
.extern sys_exec_sh_arg
.extern get_inactive_pane
.extern DirModel_get_entry
.extern DirModel_entry_name
.extern App_reload_panes
.extern App_set_status
.extern fs_errno_message
.extern i18n_get

# int ac_list_add(char *buf, size_t i, size_t max, const char *name) -> new index, or -1 when full
ac_list_add:
    mov rax, rsi
.Lala_loop:
    movzx r8d, byte ptr [rcx]
    cmp rax, rdx; jae .Lala_over
    mov [rdi + rax], r8b
    inc rax
    test r8d, r8d; jz .Lala_ret                       # the terminating NUL was copied
    inc rcx
    jmp .Lala_loop
.Lala_over:
    mov rax, -1
.Lala_ret:
    ret

# int am_collect_selected(App *app, const char *cur_name, char *buf, size_t cap)
# Writes every marked name of the active pane (cur_name when nothing is marked) as NUL terminated
# strings followed by an empty one. Returns 0, or -ENAMETOOLONG when the list does not fit.
am_collect_selected:
    push rbx; push rbp; push r12; push r13; push r14; push r15
    sub rsp, 24
    mov rbx, [rdi + App.active_pane]
    mov rbx, [rbx + FilePane.model]
    mov [rsp], rsi                                    # cur_name
    mov r12, rdx                                      # buf
    lea r13, [rcx - 1]                                # max: keep one byte for the closing empty name
    xor r14d, r14d                                    # write index
    xor r15d, r15d                                    # entry index
    xor ebp, ebp                                      # names added
.Lacs_loop:
    mov rax, [rbx + DirModel.count]
    cmp r15, rax; jae .Lacs_done
    mov rdi, rbx; mov esi, r15d
    call DirModel_get_entry
    inc r15d
    test rax, rax; jz .Lacs_loop
    test dword ptr [rax + FileEntry.flags], FE_SELECTED; jz .Lacs_loop
    mov rdi, rbx; mov rsi, rax
    call DirModel_entry_name
    mov rcx, rax
    mov rdi, r12; mov rsi, r14; mov rdx, r13
    call ac_list_add
    test rax, rax; js .Lacs_over
    mov r14, rax
    inc ebp
    jmp .Lacs_loop
.Lacs_done:
    test ebp, ebp; jnz .Lacs_close
    mov rcx, [rsp]                                    # nothing marked: the current name
    test rcx, rcx; jz .Lacs_close
    mov rdi, r12; mov rsi, r14; mov rdx, r13
    call ac_list_add
    test rax, rax; js .Lacs_over
    mov r14, rax
.Lacs_close:
    mov byte ptr [r12 + r14], 0
    xor eax, eax
    jmp .Lacs_ret
.Lacs_over:
    mov rax, -ENAMETOOLONG
.Lacs_ret:
    add rsp, 24
    pop r15; pop r14; pop r13; pop r12; pop rbp; pop rbx
    ret

# int ac_expand(frame *f) -- buffers, selection list, directories, then the template
ac_expand:
    push rbx; push r12
    sub rsp, 8
    mov rbx, rdi
    mov edi, AC_SEL_CAP
    call mem_alloc
    mov [rbx + ACF_SEL], rax
    test rax, rax; jz .Lae_oom
    mov edi, AC_CMD_CAP
    call mem_alloc
    mov [rbx + ACF_CMD], rax
    test rax, rax; jz .Lae_oom
    mov r12, [rbx + ACF_APP]
    mov rdi, r12; mov rsi, [rbx + ACF_CTX]; mov rdx, [rbx + ACF_SEL]; mov ecx, AC_SEL_CAP
    call am_collect_selected
    test eax, eax; js .Lae_ret
    mov rax, [rbx + ACF_SEL]
    mov [rbx + ACF_CTX + 16], rax
    mov rax, [r12 + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rax, [rax + DirModel.path]
    mov [rbx + ACF_CTX + 24], rax
    mov rdi, r12
    call get_inactive_pane
    mov rax, [rax + FilePane.model]
    lea rax, [rax + DirModel.path]
    mov [rbx + ACF_CTX + 32], rax
    mov rdi, [rbx + ACF_TMPL]; mov rsi, [rbx + ACF_CMD]; mov edx, AC_CMD_CAP; mov rcx, rbx
    call config_expand_cmd
    jmp .Lae_ret
.Lae_oom:
    mov eax, -ENOMEM
.Lae_ret:
    add rsp, 8
    pop r12; pop rbx
    ret

# int ac_run(frame *f) -- chdir to the active pane, run the script, come back, refresh both panes
ac_run:
    push rbx; push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, [rbx + ACF_APP]
    lea rdi, [rbx + ACF_CWD]
    mov esi, PATH_MAX
    OS_GETCWD
    test rax, rax; jns .Larn_cwd_ok
    mov byte ptr [rbx + ACF_CWD], 0
.Larn_cwd_ok:
    mov rcx, [r12 + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    OS_CHDIR
    test rax, rax; js .Larn_ret
    mov rdi, [rbx + ACF_CMD]; mov rsi, [rbx + ACF_CTX + 8]; mov rdx, [r12 + App.envp]
    call sys_exec_sh_arg
    cmp byte ptr [rbx + ACF_CWD], 0; je .Larn_post
    lea rdi, [rbx + ACF_CWD]
    OS_CHDIR
    test rax, rax; nop                                # best effort: the panes are reloaded next
.Larn_post:
    mov rdi, [r12 + App.screen]
    mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov rdi, r12; xor esi, esi
    call App_reload_panes
    xor eax, eax
.Larn_ret:
    add rsp, 8
    pop r12; pop rbx
    ret

# void ac_report(App *app, int neg_errno) -- one status line for a refused command
ac_report:
    push rbx
    mov rbx, rdi
    cmp esi, -ENAMETOOLONG; je .Lacr_long
    mov edi, esi
    call fs_errno_message
    mov rsi, rax
    jmp .Lacr_set
.Lacr_long:
    call i18n_get
    mov rsi, [rax + LangStrings.err_cmd_long]
.Lacr_set:
    mov rdi, rbx; mov edx, MSG_ERR
    call App_set_status
    pop rbx
    ret

# void App_run_expanded_cmd(App *this, const char *tmpl, const char *cur_name, const char *cur_path)
App_run_expanded_cmd:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, ACF_SIZE
    mov rbx, rdi
    mov [rsp + ACF_APP], rdi
    mov [rsp + ACF_TMPL], rsi
    mov [rsp + ACF_CTX], rdx                          # cur_name
    mov [rsp + ACF_CTX + 8], rcx                      # cur_path
    mov qword ptr [rsp + ACF_SEL], 0
    mov qword ptr [rsp + ACF_CMD], 0
    mov rdi, rsp
    call ac_expand
    mov r12d, eax
    test eax, eax; js .Larec_fail
    mov rdi, rsp
    call ac_run
    mov r12d, eax
    test eax, eax; jns .Larec_free
.Larec_fail:
    mov rdi, rbx; mov esi, r12d
    call ac_report
.Larec_free:
    mov rdi, [rsp + ACF_SEL]
    call mem_free
    mov rdi, [rsp + ACF_CMD]
    call mem_free
    add rsp, ACF_SIZE
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
