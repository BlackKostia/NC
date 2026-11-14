# Preview helper process: serves {seq, path, thumb dims} requests from fs_preview_request,
# reads the file head without ever blocking the UI and, for images, decodes the whole file and
# replies with an RGBA thumbnail (IMG_THUMB_HDR header + pixels) sized for the preview box.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PV_HDR,      16          # reply: u32 seq, i32 err, u32 len, u32 thumb len
.equ PV_REQ,      20          # request: u32 seq, path len, dims (w | h << 16), proto | cols << 8, bg
.equ PV_TREQ,     32          # frame offset of the saved {dims, mode, bg} (PvThumbReq)
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
    # [0..15] = reply header, [24..43] = request (dims/mode/bg land on PV_TREQ), [64..] = path,
    # [64+PATH_MAX..] = head bytes
    call os_signals_worker_mode
.Lph_loop:
    mov edi, r12d
    lea rsi, [rsp + PV_TREQ - 8]
    mov edx, PV_REQ
    call pv_read_exact
    test rax, rax
    jle .Lph_exit
    mov ecx, [rsp + PV_TREQ - 4]      # path length
    cmp ecx, PATH_MAX - 1
    ja .Lph_exit
    mov edi, r12d
    lea rsi, [rsp + 64]
    mov edx, ecx
    call pv_read_exact
    test rax, rax
    js .Lph_exit
    mov ecx, [rsp + PV_TREQ - 4]
    mov byte ptr [rsp + 64 + rcx], 0
    mov eax, [rsp + PV_TREQ - 8]      # seq -> reply header
    mov [rsp], eax
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
    mov edx, [rsp + 12]               # payload length (the payload itself is in shared memory)
    mov [rsi + 12], edx
    lea edx, [eax + PV_HDR]
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
    cmp dword ptr [rsp + 8 + PV_TREQ], 0
    je .Lpht_ret                      # text-only request
    call fs_preview_shm
    test rax, rax
    jz .Lpht_ret
    mov r8, rax                       # payload goes to the shared buffer
    lea rdi, [rsp + 8 + 64]           # path
    lea rsi, [rsp + 8 + 64 + PATH_MAX]
    mov edx, [rsp + 8 + 8]            # head length
    lea rcx, [rsp + 8 + PV_TREQ]
    mov r9d, PV_SHM_CAP
    sub rsp, 8
    call pv_make_thumb
    add rsp, 8
    mov [rsp + 8 + 12], eax
.Lpht_ret:
    ret


# size_t pv_make_thumb(const char *path, const uint8_t *head, size_t head_len,
#                      const PvThumbReq *req /*dims, proto | cols << 8, bg*/, uint8_t *out, size_t cap)
# -> IMG_THUMB_HDR + payload for a decoded image (RGBA pixels for block output, a ready Sixel or
#    Kitty escape stream for pixel protocols), IMG_THUMB_HDR alone for an undecodable image,
#    0 when the file is not an image.
pv_make_thumb:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, Image._size + 8
    mov rbx, rdi
    mov r12, r8
    mov r13, rcx
    mov r14, r9
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rbx
    call img_detect
    test eax, eax
    jz .Lmt_ret
    mov [r12], eax                    # header: fmt, src w/h = 0, out 0x0 (= undecodable)
    mov qword ptr [r12 + 4], 0
    mov dword ptr [r12 + 12], 0
    mov r15d, IMG_THUMB_HDR
    mov rdi, rbx
    mov esi, eax
    mov rdx, rsp
    call pv_load_image
    test eax, eax
    jnz .Lmt_done
    mov rdi, r12
    mov rsi, rsp
    mov rdx, r13
    mov rcx, r14
    call pv_render_payload
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

# Internal: size_t pv_render_payload(uint8_t *out, const Image *img, const PvThumbReq *req, size_t cap)
pv_render_payload:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov eax, [r12 + Image.w]
    mov [rbx + 4], eax
    mov eax, [r12 + Image.h]
    mov [rbx + 8], eax
    mov rdi, r12
    mov rsi, r13
    call pv_out_size                  # eax = ow, edx = oh
    mov [rbx + 12], ax
    mov [rbx + 14], dx
    mov [rsp], eax
    mov [rsp + 4], edx
    movzx eax, byte ptr [r13 + 4]     # protocol
    cmp eax, IMG_PROTO_SIXEL
    jae .Lrp_pixels
    mov eax, [rsp]                    # block output: plain RGBA
    imul eax, [rsp + 4]
    lea r15, [rax * 4 + IMG_THUMB_HDR]
    cmp r15, r14
    ja .Lrp_none
    mov rdi, r12
    lea rsi, [rbx + IMG_THUMB_HDR]
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    call img_scale
    mov rax, r15
    jmp .Lrp_ret
.Lrp_pixels:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call pv_encode_pixels
    jmp .Lrp_ret
.Lrp_none:
    mov eax, IMG_THUMB_HDR
.Lrp_ret:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (int ow, int oh) pv_out_size(const Image *img, const PvThumbReq *req)
# Block output always fills the box; pixel protocols never upscale (crisp small images).
pv_out_size:
    movzx edx, word ptr [rsi]         # box w
    movzx ecx, word ptr [rsi + 2]     # box h
    mov eax, [rdi + Image.w]
    mov r8d, [rdi + Image.h]
    cmp byte ptr [rsi + 4], IMG_PROTO_SIXEL
    jb .Los_fit
    cmp eax, edx
    ja .Los_fit
    cmp r8d, ecx
    ja .Los_fit
    mov edx, r8d                      # fits: native size
    ret
.Los_fit:
    mov edi, eax
    mov esi, r8d
    jmp img_fit

# Internal: size_t pv_encode_pixels(uint8_t *out, const Image *img, const PvThumbReq *req, size_t cap)
pv_encode_pixels:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    movzx eax, word ptr [rbx + 12]
    movzx ecx, word ptr [rbx + 14]
    imul eax, ecx
    lea rdi, [rax * 4]
    call mem_alloc
    mov r15, rax
    mov eax, IMG_THUMB_HDR
    test r15, r15
    jz .Lep_ret
    mov rdi, r12
    mov rsi, r15
    movzx edx, word ptr [rbx + 12]
    movzx ecx, word ptr [rbx + 14]
    call img_scale
    mov rdi, r15
    movzx esi, word ptr [rbx + 12]
    movzx edx, word ptr [rbx + 14]
    lea r8, [rbx + IMG_THUMB_HDR]
    lea r9, [r14 - IMG_THUMB_HDR]
    cmp byte ptr [r13 + 4], IMG_PROTO_KITTY
    je .Lep_kitty
    mov ecx, [r13 + 8]                # Sixel: alpha blended over the pane background
    call img_sixel_encode
    jmp .Lep_done
.Lep_kitty:
    movzx ecx, byte ptr [r13 + 5]     # box cols (0 = native pixel size)
    test ecx, ecx
    jz 1f
    movzx eax, word ptr [rbx + 12]    # picture cols = ceil(ow * box cols / box px w)
    imul eax, ecx
    movzx ecx, word ptr [r13]
    add eax, ecx
    dec eax
    push rdx
    xor edx, edx
    div ecx
    pop rdx
    mov ecx, eax
1:  call img_kitty_encode
.Lep_done:
    add eax, IMG_THUMB_HDR
    push rax
    mov rdi, r15
    call mem_free
    pop rax
.Lep_ret:
    pop r15
    pop r14
    pop r13
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
