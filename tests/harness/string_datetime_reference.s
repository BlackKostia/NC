# Frozen reference oracle: the hand-written asm that src/core/string_datetime.c replaced (tests/test_c_string.py diffs against it)
# Core String, Formatting, and Path Utilities — string datetime (split from string.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.section .text
.global format_datetime_raw

format_datetime_raw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call format_datetime_raw__epoch_rem_epoch
    # era = (z >= 0 ? z : z - 146096) / 146097
    call format_datetime_raw__era
    # doe = z - era * 146097 (0..146096)
    call format_datetime_raw__doe
    # day = doy - (153*mp + 2)/5 + 1
    call format_datetime_raw__day
    # month = mp + (mp < 10 ? 3 : -9)
    call format_datetime_raw__month
    # year = yoe + era*400 + (month <= 2 ? 1 : 0)
    call format_datetime_raw__year
    # rax = year, r9 = month, r8 = day, r12 = sec_in_day
    # Clamp year to 0..9999 for 4-digit print
    call format_datetime_raw__clamp_year_digit_print
    # Write MM
    call format_datetime_raw__write_mm
    # Write DD
    call format_datetime_raw__write_dd
    # hh = r12 / 3600, mm = (r12 % 3600) / 60
    call format_datetime_raw__r12_mm
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# format_datetime_raw step: epoch rem epoch (runs on the caller's frame)
format_datetime_raw__epoch_rem_epoch:
    lea rsp, [rsp - 8]
    mov rbx, rsi              # buf

    # z = epoch / 86400, rem = epoch % 86400 (Euclidean floor)
    mov rax, rdi
    mov rcx, 86400
    cqo
    idiv rcx                  # rax = days, rdx = rem
    test rdx, rdx
    jns .Lfdt_rem_ok
    add rdx, 86400
    dec rax
.Lfdt_rem_ok:
    mov r12, rdx              # seconds in day (0..86399)
    add rax, 719468           # shift to 0000-03-01 epoch

.Lformat_datetime_raw__epoch_rem_epoch_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: era (runs on the caller's frame)
format_datetime_raw__era:
    lea rsp, [rsp - 8]
    mov r8, rax
    test r8, r8
    jns .Lfdt_era_pos
    sub r8, 146096
.Lfdt_era_pos:
    mov r9, rax               # save z
    mov rax, r8
    mov rcx, 146097
    cqo
    idiv rcx
    mov r13, rax              # era

.Lformat_datetime_raw__era_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: doe (runs on the caller's frame)
format_datetime_raw__doe:
    lea rsp, [rsp - 8]
    imul rcx, r13, 146097
    mov r14, r9
    sub r14, rcx              # doe

    # yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, r14
    xor edx, edx
    mov rcx, 1460
    div rcx
    mov r8, r14
    sub r8, rax

    mov rax, r14
    xor edx, edx
    mov rcx, 36524
    div rcx
    add r8, rax

    mov rax, r14
    xor edx, edx
    mov rcx, 146096
    div rcx
    sub r8, rax

    mov rax, r8
    xor edx, edx
    mov rcx, 365
    div rcx
    mov r15, rax              # yoe (0..399)

    # doy = doe - (365*yoe + yoe/4 - yoe/100)
    imul r8, r15, 365
    mov rax, r15
    shr rax, 2
    add r8, rax
    mov rax, r15
    xor edx, edx
    mov rcx, 100
    div rcx
    sub r8, rax
    mov r9, r14
    sub r9, r8                # doy (0..365)

    # mp = (5*doy + 2) / 153
    lea rax, [r9 + r9*4 + 2]
    xor edx, edx
    mov rcx, 153
    div rcx
    mov r10, rax              # mp (0..11)

.Lformat_datetime_raw__doe_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: day (runs on the caller's frame)
format_datetime_raw__day:
    lea rsp, [rsp - 8]
    imul rax, r10, 153
    add rax, 2
    xor edx, edx
    mov rcx, 5
    div rcx
    mov r8, r9
    sub r8, rax
    inc r8                    # day (1..31)

.Lformat_datetime_raw__day_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: month (runs on the caller's frame)
format_datetime_raw__month:
    lea rsp, [rsp - 8]
    mov r9, r10
    cmp r10, 10
    jae .Lfdt_m_sub
    add r9, 3
    jmp .Lfdt_m_ok
.Lfdt_m_sub:
    sub r9, 9
.Lfdt_m_ok:
.Lformat_datetime_raw__month_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: year (runs on the caller's frame)
format_datetime_raw__year:
    lea rsp, [rsp - 8]
    imul rax, r13, 400
    add rax, r15
    cmp r9, 2
    ja .Lfdt_y_ok
    inc rax
.Lfdt_y_ok:
.Lformat_datetime_raw__year_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: Clamp year to for digit print (runs on the caller's frame)
format_datetime_raw__clamp_year_digit_print:
    lea rsp, [rsp - 8]
    cmp rax, 0
    jge .Lfdt_y_nonneg
    xor eax, eax
.Lfdt_y_nonneg:
    cmp rax, 9999
    jle .Lfdt_y_fit
    mov rax, 9999
.Lfdt_y_fit:
    # Write YYYY
    mov rcx, 1000
    xor edx, edx
    div rcx
    add al, '0'
    mov byte ptr [rbx + 0], al
    mov rax, rdx
    mov rcx, 100
    xor edx, edx
    div rcx
    add al, '0'
    mov byte ptr [rbx + 1], al
    mov rax, rdx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 2], al
    mov byte ptr [rbx + 3], dl
    mov byte ptr [rbx + 4], '-'

.Lformat_datetime_raw__clamp_year_digit_print_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: Write MM (runs on the caller's frame)
format_datetime_raw__write_mm:
    lea rsp, [rsp - 8]
    mov rax, r9
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 5], al
    mov byte ptr [rbx + 6], dl
    mov byte ptr [rbx + 7], '-'

.Lformat_datetime_raw__write_mm_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: Write DD (runs on the caller's frame)
format_datetime_raw__write_dd:
    lea rsp, [rsp - 8]
    mov rax, r8
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 8], al
    mov byte ptr [rbx + 9], dl
    mov byte ptr [rbx + 10], ' '

.Lformat_datetime_raw__write_dd_ret:
    lea rsp, [rsp + 8]
    ret

# format_datetime_raw step: r12 mm (runs on the caller's frame)
format_datetime_raw__r12_mm:
    lea rsp, [rsp - 8]
    mov rax, r12
    xor edx, edx
    mov rcx, 3600
    div rcx
    mov r8, rdx               # rem sec
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 11], al
    mov byte ptr [rbx + 12], dl
    mov byte ptr [rbx + 13], ':'

    mov rax, r8
    xor edx, edx
    mov rcx, 60
    div rcx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 14], al
    mov byte ptr [rbx + 15], dl
    mov byte ptr [rbx + 16], 0

.Lformat_datetime_raw__r12_mm_ret:
    lea rsp, [rsp + 8]
    ret
