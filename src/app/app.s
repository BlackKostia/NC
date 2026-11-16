# App Controller Class (Inherits from Object)
# Coordinates layout, polymorphic widget rendering, input routing, dialogs, and FS actions.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_App:            .asciz "App"

App_vtbl:
    OBJECT_VTBL_SLOTS str_App, Object_vtbl, App._size, App_dtor

.section .text
.global App_new
.global App_dtor
.global App_vtbl

.extern g_git_defer

# App *App_new(const char *left_path, const char *right_path, char **envp, int lang_override)
App_new:
    push rbx
    push r12
    push r13
    push r14
    mov dword ptr [rip + g_git_defer], 1
    push r15
    call App_new__left_path
    jz .Lan_fail
    call App_new__cfg_theme
    call App_new__apply_show_hidden_sort
    mov rdi, rbx
    call App_layout

    mov rax, rbx
.Lan_fail:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# App_new step: left_path (runs on the caller's frame)
App_new__left_path:
    lea rsp, [rsp - 8]
    mov r12, rdi              # left_path
    mov r13, rsi              # right_path
    mov r14, rdx              # envp
    mov r15d, ecx             # lang_override (-1 = auto)

    NEW_OBJ App_vtbl, App._size
    test rax, rax
.LApp_new__left_path_ret:
    lea rsp, [rsp + 8]
    ret

# App_new step: CFG_THEME (runs on the caller's frame)
App_new__cfg_theme:
    lea rsp, [rsp - 8]
    mov rbx, rax

    mov [rbx + App.envp], r14
    mov rdi, r14
    call config_load
    mov rdi, r14
    call kbd_layout_load              # keyboard layouts from *.layout files
    mov rdi, rbx
    call App_du_init                  # Disk Usage progress window + Esc cancel
    mov rdi, r14
    call DirModel_init_env
    mov dword ptr [rbx + App.running], 1
    mov dword ptr [rbx + App.need_redraw], 1
    mov dword ptr [rbx + App.theme_idx], 0
    mov dword ptr [rbx + App.right_mode], RIGHT_MODE_PANE

    mov rdi, r14
    call nav_state_init
    call config_get
    mov ecx, [rax + 0]        # CFG_THEME
    test ecx, ecx
    js .Lan_chk_cfg_lang
    mov [rbx + App.theme_idx], ecx
.Lan_chk_cfg_lang:
    cmp r15d, 0
    jge .Lan_set_lang
    lea rdi, [rax + CFG_LANG_ID]      # duoprc `lang = <id>`
    call i18n_find
    mov r15d, eax
    test eax, eax
    jns .Lan_set_lang
    mov rdi, r14
    call i18n_detect_env
    mov r15d, eax
.Lan_set_lang:
    mov edi, r15d
    call i18n_set_lang
    mov [rbx + App.lang], rax
    call i18n_get_idx
    mov [rbx + App.lang_idx], eax

    mov edi, [rbx + App.theme_idx]
    call theme_get
    mov [rbx + App.theme], rax

    lea rdi, [rbx + App.term_w]
    lea rsi, [rbx + App.term_h]
    call sys_get_winsize

    mov edi, [rbx + App.term_w]
    mov esi, [rbx + App.term_h]
    call ScreenBuffer_new
    mov [rbx + App.screen], rax

    mov rdi, rbx
    call HeaderBar_new
    mov [rbx + App.header_bar], rax

    mov rdi, rbx
    call FunctionBar_new
    mov [rbx + App.func_bar], rax

.LApp_new__cfg_theme_ret:
    lea rsp, [rsp + 8]
    ret

# App_new step: Apply show_hidden sort_mode from duoprc if configured (runs on the caller's frame)
App_new__apply_show_hidden_sort:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    call StatusBar_new
    mov [rbx + App.status_bar], rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    call FilePane_new
    mov [rbx + App.left_pane], rax

    mov rdi, rbx
    mov rsi, r13
    mov edx, 2
    call FilePane_new
    mov [rbx + App.right_pane], rax

    # Apply show_hidden / sort_mode from duoprc if configured
    mov rdi, r14
    call nav_state_init
    call config_get
    mov r12, rax
    mov ecx, [r12 + 8]        # CFG_HIDDEN
    test ecx, ecx
    js .Lan_cfg_sort
    mov rax, [rbx + App.left_pane]
    mov rax, [rax + FilePane.model]
    mov [rax + DirModel.show_hidden], ecx
    mov rdi, rax
    call DirModel_apply_filter
    mov ecx, [r12 + 8]
    mov rax, [rbx + App.right_pane]
    mov rax, [rax + FilePane.model]
    mov [rax + DirModel.show_hidden], ecx
    mov rdi, rax
    call DirModel_apply_filter
.Lan_cfg_sort:
    mov ecx, [r12 + 12]       # CFG_SORT
    test ecx, ecx
    js .Lan_cfg_done
    mov rax, [rbx + App.left_pane]
    mov rax, [rax + FilePane.model]
    mov [rax + DirModel.sort_mode], ecx
    mov rdi, rax
    call DirModel_sort
    mov ecx, [r12 + 12]
    mov rax, [rbx + App.right_pane]
    mov rax, [rax + FilePane.model]
    mov [rax + DirModel.sort_mode], ecx
    mov rdi, rax
    call DirModel_sort
.Lan_cfg_done:

    mov rdi, rbx
    call PreviewPane_new
    mov [rbx + App.preview_pane], rax

    mov rdi, rbx
    mov rsi, [rbx + App.left_pane]
    call App_set_active_pane

.LApp_new__apply_show_hidden_sort_ret:
    lea rsp, [rsp + 8]
    ret

# void App_dtor(App *this)
App_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + App.active_dialog]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.preview_pane]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.right_pane]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.left_pane]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.status_bar]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.func_bar]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.header_bar]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.screen]
    DELETE_OBJ rdi
    call dirwatch_cleanup
    call nav_state_cleanup
    call du_cache_cleanup
    call du_links_cleanup
    pop rbx
    ret
