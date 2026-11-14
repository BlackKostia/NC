# Directory Watch: kernel change notifications for the two displayed directories
#
# One non-blocking watch fd (inotify on Linux, via PAL) with up to two watches (slot 0 =
# left pane, slot 1 = right pane). Both panes on the same directory share the kernel watch
# descriptor. dirwatch_poll drains pending events and classifies them per slot:
#   structural (entries created / deleted / renamed, overflow) -> listing must be reloaded
#   content    (file data or attributes changed)               -> cached stats are stale

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ DW_MASK, PAL_IN_CREATE | PAL_IN_DELETE | PAL_IN_MOVED_FROM | PAL_IN_MOVED_TO | PAL_IN_MODIFY | PAL_IN_ATTRIB | PAL_IN_DELETE_SELF | PAL_IN_MOVE_SELF
.equ DW_STRUCT, PAL_IN_CREATE | PAL_IN_DELETE | PAL_IN_MOVED_FROM | PAL_IN_MOVED_TO | PAL_IN_DELETE_SELF | PAL_IN_MOVE_SELF | PAL_IN_Q_OVERFLOW
.equ DW_BUF, 8192

.section .bss
.align 8
g_dw_state: .space 8          # DWState* (heap): paths + event buffer
g_dw_fd1:   .space 4          # watch fd + 1 (0 = not initialized)
g_dw_wd:    .space 8          # int wd[2] (-1 = none)

.struct 0
DW.path0: .space PATH_MAX
DW.path1: .space PATH_MAX
DW.buf:   .space DW_BUF
DW._size:

.section .text
.global dirwatch_init
.global dirwatch_fd
.global dirwatch_set
.global dirwatch_poll
.global dirwatch_cleanup

# int dirwatch_init(void) -> 0 or -errno (feature simply stays off on failure)
dirwatch_init:
    push rbx
    cmp dword ptr [rip + g_dw_fd1], 0
    jne .Ldwi_ok
    mov edi, DW._size
    call mem_alloc
    test rax, rax
    jz .Ldwi_nomem
    mov rbx, rax
    call os_watch_init
    test rax, rax
    js .Ldwi_fail
    inc eax
    mov [rip + g_dw_fd1], eax
    mov [rip + g_dw_state], rbx
    mov dword ptr [rip + g_dw_wd], -1
    mov dword ptr [rip + g_dw_wd + 4], -1
.Ldwi_ok:
    xor eax, eax
    pop rbx
    ret
.Ldwi_fail:
    push rax
    mov rdi, rbx
    call mem_free
    pop rax
    pop rbx
    ret
.Ldwi_nomem:
    mov rax, -ENOMEM
    pop rbx
    ret

# int dirwatch_fd(void) -> watch fd or -1
dirwatch_fd:
    mov eax, [rip + g_dw_fd1]
    dec eax
    ret

# void dirwatch_set(int slot, const char *path) -- (re)targets a slot; no-op if unchanged
dirwatch_set:
    push rbx
    push r12
    push r13
    mov r12d, edi
    and r12d, 1
    mov r13, rsi
    cmp dword ptr [rip + g_dw_fd1], 0
    je .Ldws_ret
    mov rbx, [rip + g_dw_state]
    mov eax, r12d
    imul rax, rax, PATH_MAX
    add rbx, rax                      # &path[slot]
    mov rdi, rbx
    mov rsi, r13
    call str_cmp
    test eax, eax
    jz .Ldws_ret

    # Drop the old watch unless the other slot shares its descriptor
    lea rcx, [rip + g_dw_wd]
    mov esi, [rcx + r12 * 4]
    test esi, esi
    js .Ldws_add
    mov eax, r12d
    xor eax, 1
    cmp esi, [rcx + rax * 4]
    je .Ldws_add
    mov edi, [rip + g_dw_fd1]
    dec edi
    call os_watch_rm
.Ldws_add:
    mov rdi, rbx
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy
    mov edi, [rip + g_dw_fd1]
    dec edi
    mov rsi, r13
    mov edx, DW_MASK
    call os_watch_add
    test rax, rax
    jns .Ldws_store
    mov eax, -1
.Ldws_store:
    lea rcx, [rip + g_dw_wd]
    mov [rcx + r12 * 4], eax
.Ldws_ret:
    pop r13
    pop r12
    pop rbx
    ret

# uint32_t dirwatch_poll(void)
# Drains all pending events. Returns bits: 1 = slot0 structural, 2 = slot0 content,
# 4 = slot1 structural, 8 = slot1 content.
dirwatch_poll:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                       # [0]=pos, [8]=wd, [12]=mask
    xor r15d, r15d                    # result bits
    cmp dword ptr [rip + g_dw_fd1], 0
    je .Ldwp_ret
    mov rbx, [rip + g_dw_state]
.Ldwp_read:
    mov edi, [rip + g_dw_fd1]
    dec edi
    lea rsi, [rbx + DW.buf]
    mov edx, DW_BUF
    call os_watch_read
    test rax, rax
    jle .Ldwp_ret
    mov r12, rax
    mov qword ptr [rsp], 0
.Ldwp_next:
    lea rdi, [rbx + DW.buf]
    mov rsi, r12
    mov rdx, rsp
    lea rcx, [rsp + 8]
    lea r8, [rsp + 12]
    call os_watch_next
    test eax, eax
    jz .Ldwp_read
    mov r13d, [rsp + 12]              # mask
    mov r14d, 2                       # content bit (slot 0)
    test r13d, DW_STRUCT
    jz .Ldwp_kind
    mov r14d, 1                       # structural bit (slot 0)
.Ldwp_kind:
    test r13d, PAL_IN_Q_OVERFLOW
    jnz .Ldwp_all                     # lost events: refresh both panes
    mov eax, [rsp + 8]
    cmp eax, [rip + g_dw_wd]
    jne .Ldwp_s1
    or r15d, r14d
.Ldwp_s1:
    cmp eax, [rip + g_dw_wd + 4]
    jne .Ldwp_next
    mov eax, r14d
    shl eax, 2
    or r15d, eax
    jmp .Ldwp_next
.Ldwp_all:
    or r15d, 1 | 4
    jmp .Ldwp_next
.Ldwp_ret:
    mov eax, r15d
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void dirwatch_cleanup(void) -- closes watch fd and frees g_dw_state
dirwatch_cleanup:
    push rbx
    mov eax, [rip + g_dw_fd1]
    test eax, eax
    jz .Ldwc_state
    lea edi, [eax - 1]
    OS_CLOSE
    mov dword ptr [rip + g_dw_fd1], 0
.Ldwc_state:
    mov rbx, [rip + g_dw_state]
    test rbx, rbx
    jz .Ldwc_done
    mov qword ptr [rip + g_dw_state], 0
    mov rdi, rbx
    call mem_free
.Ldwc_done:
    mov dword ptr [rip + g_dw_wd], -1
    mov dword ptr [rip + g_dw_wd + 4], -1
    pop rbx
    ret
