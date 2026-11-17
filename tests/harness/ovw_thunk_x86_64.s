# Calls the frozen fo_open_overwrite the way src/fs/task_conflict.s does: r10 = new_mode (the in-place open of the old code reads
# its creation mode from the r10 its caller left behind; the C version takes it from the argument).
.intel_syntax noprefix
.section .text
.global ovw_ref_open
ovw_ref_open:                       # (dfd, name, dst_mode, new_mode, out_tmp) -> rax:rdx
    mov r10d, ecx
    jmp ref_fo_open_overwrite
