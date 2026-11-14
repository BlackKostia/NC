# Preview helper process: serves {seq, path, thumb dims} requests from fs_preview_request,
# reads the file head without ever blocking the UI and, for images, decodes the whole file and
# replies with an RGBA thumbnail (IMG_THUMB_HDR header + pixels) sized for the preview box.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PV_HDR,      16          # reply: u32 seq, i32 err, u32 len, u32 thumb len
.equ PV_REQ,      12          # request: u32 seq, u32 path len, u16 thumb w | u16 thumb h << 16
.equ PV_MAX_IMG,  268435456   # never decode files above 256 MiB

.section .text
.global pv_helper_main
.global pv_make_thumb

# ------------------------------------------------------------------------------
# Helper process main loop (never returns). r12d = request fd, r13d = reply fd.
# ------------------------------------------------------------------------------
pv_helper_main:
    and rsp, -16
    sub rsp, PATH_MAX + PREVIEW_BUF_SIZE + IMG_THUMB_CAP + 64
    # [0..15] = request header, [64..] = path, [64+PATH_MAX..] = data, then the thumbnail
    call os_signals_worker_mode
.Lph_loop:
    mov edi, r12d
    mov rsi, rsp
    mov edx, PV_REQ
    call pv_read_exact
    test rax, rax
    jle .Lph_exit
    mov ecx, [rsp + 4]                # path length
    cmp ecx, PATH_MAX - 1
    ja .Lph_exit
    mov edi, r12d
    lea rsi, [rsp + 64]
    mov edx, ecx
    call pv_read_exact
    test rax, rax
    js .Lph_exit
    mov ecx, [rsp + 4]
    mov byte ptr [rsp + 64 + rcx], 0
    mov eax, [rsp + 8]                # request thumb dims -> [16]
    mov [rsp + 16], eax
    mov dword ptr [rsp + 8], 0        # len
    mov edi, AT_FDCWD
    lea rsi, [rsp + 64]
    mov edx, O_RDONLY | O_NONBLOCK | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    mov [rsp + 4], eax                # err (fd if >= 0)
    test rax, rax
    js .Lph_reply
    mov r14d, eax
    xor r15d, r15d                    # bytes read
.Lph_read:
    cmp r15d, PREVIEW_BUF_SIZE
    jae .Lph_close
    mov edi, r14d
    lea rsi, [rsp + 64 + PATH_MAX]
    add rsi, r15
    mov edx, PREVIEW_BUF_SIZE
    sub edx, r15d
    OS_READ
    cmp rax, -EINTR
    je .Lph_read
    test rax, rax
    jle .Lph_close                    # EOF, error or EAGAIN (empty FIFO)
    add r15d, eax
    jmp .Lph_read
.Lph_close:
    mov edi, r14d
    OS_CLOSE
    mov dword ptr [rsp + 4], 0
    mov [rsp + 8], r15d
.Lph_reply:
    call pv_helper_thumb              # sets the thumbnail length ([12], 0 = none)
    # reply header at [64+PATH_MAX-12] so header + data are one contiguous write
    lea rsi, [rsp + 64 + PATH_MAX - PV_HDR]
    mov eax, [rsp]
    mov [rsi], eax
    mov eax, [rsp + 4]
    mov [rsi + 4], eax
    mov eax, [rsp + 8]
    mov [rsi + 8], eax
    mov edx, [rsp + 12]
    mov [rsi + 12], edx
    add edx, eax
    add edx, PV_HDR
    mov edi, r13d
    call sys_write_all
    test rax, rax
    js .Lph_exit
    jmp .Lph_loop
.Lph_exit:
    xor edi, edi
    OS_EXIT

# Internal (helper frame, called with rsp = frame - 8): decode an image head into a thumbnail
pv_helper_thumb:
    mov dword ptr [rsp + 8 + 12], 0
    cmp dword ptr [rsp + 8 + 4], 0    # open failed: no thumbnail
    jl .Lpht_ret
    mov eax, [rsp + 8 + 16]           # requested thumb dims (0 = text-only request)
    test eax, eax
    jz .Lpht_ret
    lea rdi, [rsp + 8 + 64]           # path
    lea rsi, [rsp + 8 + 64 + PATH_MAX]
    mov edx, [rsp + 8 + 8]            # head length
    movzx ecx, ax                     # tw
    shr eax, 16
    mov r8d, eax                      # th
    lea r9, [rsi + rdx]               # thumbnail goes right after the head bytes
    sub rsp, 8
    call pv_make_thumb
    add rsp, 8
    mov [rsp + 8 + 12], eax
.Lpht_ret:
    ret


# size_t pv_make_thumb(const char *path, const uint8_t *head, size_t head_len, int tw, int th,
#                      uint8_t *out)
# -> IMG_THUMB_HDR + ow*oh*4 for a decoded image, IMG_THUMB_HDR alone for an image that cannot be
#    decoded (unsupported variant / corrupt), 0 when the file is not an image.
pv_make_thumb:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, Image._size + 8
    mov rbx, rdi
    mov r12, r9
    mov r13d, ecx
    mov r14d, r8d
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rbx
    call img_detect
    test eax, eax
    jz .Lmt_ret
    mov [r12], eax                    # header: fmt, src w/h = 0, thumb 0x0 (= undecodable)
    mov qword ptr [r12 + 4], 0
    mov dword ptr [r12 + 12], 0
    mov r15d, IMG_THUMB_HDR
    cmp r13d, IMG_THUMB_MAXW
    jbe 1f
    mov r13d, IMG_THUMB_MAXW
1:  cmp r14d, IMG_THUMB_MAXH
    jbe 2f
    mov r14d, IMG_THUMB_MAXH
2:  test r13d, r13d
    jz .Lmt_done
    test r14d, r14d
    jz .Lmt_done
    mov rdi, rbx
    mov esi, eax
    mov rdx, rsp
    call pv_load_image
    test eax, eax
    jnz .Lmt_done
    mov rdi, r12
    mov rsi, rsp
    mov edx, r13d
    mov ecx, r14d
    call pv_thumb_scale
    mov r15d, eax
    mov rdi, rsp
    call img_free
.Lmt_done:
    mov eax, r15d
.Lmt_ret:
    add rsp, Image._size + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: size_t pv_thumb_scale(uint8_t *out, const Image *img, int tw, int th)
# Fits the picture into tw x th (small pictures keep their size) and writes header + pixels.
pv_thumb_scale:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + Image.w]
    mov [rbx + 4], eax
    mov r8d, [r12 + Image.h]
    mov [rbx + 8], r8d
    cmp eax, edx
    ja .Lts_fit
    cmp r8d, ecx
    ja .Lts_fit
    mov edx, r8d                      # already fits: native size
    jmp .Lts_go
.Lts_fit:
    mov edi, eax
    mov esi, r8d
    call img_fit                      # eax = ow, edx = oh
.Lts_go:
    mov [rbx + 12], ax
    mov [rbx + 14], dx
    push rax
    push rdx
    mov rdi, r12
    lea rsi, [rbx + IMG_THUMB_HDR]
    mov ecx, edx
    mov edx, eax
    call img_scale
    pop rdx
    pop rax
    imul eax, edx
    lea eax, [rax * 4 + IMG_THUMB_HDR]
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: int pv_load_image(const char *path, int fmt, Image *img) -- mmap + decode
pv_load_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileStat._size + 8
    mov r12d, esi
    mov r13, rdx
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    mov ebx, eax
    mov eax, IMG_E_FORMAT
    test ebx, ebx
    js .Lli_ret
    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    mov r14, [rsp + FileStat.size]
    test eax, eax
    jnz .Lli_close
    test r14, r14
    jz .Lli_close
    cmp r14, PV_MAX_IMG
    ja .Lli_close
    mov edi, ebx
    mov rsi, r14
    call os_mmap_file_ro
    mov r15, rax
    test rax, rax
    jz .Lli_close
    mov rdi, r15
    mov rsi, r14
    mov edx, r12d
    mov rcx, r13
    call img_decode
    push rax
    sub rsp, 8
    mov rdi, r15
    mov rsi, r14
    call os_munmap
    add rsp, 8
    pop rax
    jmp .Lli_closefd
.Lli_close:
    mov eax, IMG_E_FORMAT
.Lli_closefd:
    push rax
    sub rsp, 8
    mov edi, ebx
    OS_CLOSE
    add rsp, 8
    pop rax
.Lli_ret:
    add rsp, FileStat._size + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
