# Duop — Multi-Platform Pure Assembly Project Makefile (compile-time OS & ARCH selection)

OS      ?= linux
ARCH    ?= x86_64
MEMCHECK ?= 0
TARGET  := duop
BUILD   := build
VERSION := $(strip $(shell cat VERSION))
PAL_INC := include/os/$(OS)/$(ARCH)

AS      := as
LD      := ld
CC      := gcc
CTARGET :=
ifeq ($(ARCH),aarch64)
AS      := aarch64-linux-gnu-as
LD      := aarch64-linux-gnu-ld
CC      := clang
CTARGET := --target=aarch64-linux-gnu -mno-outline-atomics -Wno-unused-command-line-argument
endif
ASFLAGS := -I $(PAL_INC) -I include -I $(BUILD) -g --strip-local-absolute
LDFLAGS := -z noexecstack --gc-sections
# Freestanding C23 (docs/HYBRID_PORTABILITY_PLAN.md "ABI-прапорці збірки"); no libc, no PIE/CET/unwind tables
CFLAGS  := $(CTARGET) -std=gnu2x -Os -ffreestanding -fno-pic -fno-pie \
	-fcf-protection=none -fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident \
	-funsigned-char -fno-strict-aliasing -fno-common -ffunction-sections -fdata-sections \
	-g -Wall -Wextra -Werror -Wframe-larger-than=4608 -I include -I $(BUILD)
ifneq ($(ARCH),aarch64)
CFLAGS  += -fno-stack-clash-protection
endif

ifneq ($(ARCH),x86_64)
BUILD   := build_$(ARCH)
endif

ifeq ($(MEMCHECK),1)
TARGET  := duop_memcheck
BUILD   := build_mc
ASFLAGS += --defsym MEMCHECK=1
CFLAGS  += -DMEMCHECK=1
endif

VER_INC := $(BUILD)/version.inc

SRCS := \
	src/main.s \
	src/core/memcheck.s \
	src/tui/i18n.s \
	src/tui/i18n_keys.s \
	src/fs/dir_model.s \
	src/fs/dir_model_load.s \
	src/fs/dir_model_stream.s \
	src/fs/dir_model_filter.s \
	src/fs/dir_model_stat.s \
	src/fs/dir_model_select.s \
	src/fs/dir_sort.s \
	src/fs/dir_sort_intro.s \
	src/fs/dir_sort_radix.s \
	src/fs/dir_sort_prefix.s \
	src/fs/dir_cache.s \
	src/fs/dir_cache_fetch.s \
	src/fs/file_ops.s \
	src/fs/file_ops_copy_at.s \
	src/fs/file_ops_copy_link.s \
	src/fs/file_ops_overwrite.s \
	src/fs/file_ops_copy.s \
	src/fs/file_ops_delete.s \
	src/fs/file_ops_read.s \
	src/fs/task.s \
	src/fs/task_worker.s \
	src/fs/task_control.s \
	src/fs/task_conflict.s \
	src/fs/dir_watch.s \
	src/fs/preview_io.s \
	src/fs/preview_helper.s \
	src/fs/img_core.s \
	src/fs/nav_state.s \
	src/fs/nav_state_history.s \
	src/fs/nav_state_bookmarks.s \
	src/fs/nav_state_frecency.s \
	src/fs/pkg_fetch.s \
	src/fs/pkg_archive.s \
	src/fs/pkg_manager.s \
	src/fs/pkg_verify.s \
	src/fs/pkg_actions.s \
	src/fs/pkg_popup.s \
	src/fs/pkg_preview.s \
	src/fs/pkg_registry.s \
	src/fs/pkg_vfs.s \
	src/fs/pkg_vfs_pane.s \
	src/fs/pkg_cli.s \
	src/fs/archive_vfs.s \
	src/fs/archive_extract.s \
	src/fs/git_status.s \
	src/fs/git_status_query.s \
	src/fs/git_trust.s \
	src/fs/trash_undo.s \
	src/fs/trash_undo_ops.s \
	src/fs/trash_info.s \
	src/ui/header_bar.s \
	src/ui/header_bar_render.s \
	src/ui/header_bar_git.s \
	src/ui/function_bar.s \
	src/ui/status_bar.s \
	src/ui/status_bar_render.s \
	src/ui/file_pane.s \
	src/ui/file_pane_layout.s \
	src/ui/file_pane_render.s \
	src/ui/file_pane_keys.s \
	src/ui/file_pane_mouse.s \
	src/ui/file_pane_tabs.s \
	src/ui/preview_pane.s \
	src/ui/preview_mode.s \
	src/ui/img_overlay.s \
	src/ui/img_quad.s \
	src/ui/img_braille.s \
	src/ui/preview_pane_render.s \
	src/ui/preview_pane_mouse.s \
	src/ui/dialogs.s \
	src/ui/dialogs_confirm.s \
	src/ui/dialogs_input.s \
	src/ui/dialogs_input_keys.s \
	src/ui/dialogs_help.s \
	src/ui/dialogs_help_input.s \
	src/ui/viewer_dialog.s \
	src/ui/viewer_image.s \
	src/ui/viewer_pixels.s \
	src/ui/viewer_zoom.s \
	src/ui/viewer_zoom_rect.s \
	src/ui/viewer_scrollbar.s \
	src/ui/view_as_dialog.s \
	src/ui/viewer_dialog_end.s \
	src/ui/viewer_dialog_render.s \
	src/ui/viewer_dialog_input.s \
	src/ui/progress_dialog.s \
	src/ui/progress_dialog_render.s \
	src/ui/progress_dialog_input.s \
	src/ui/conflict_dialog.s \
	src/ui/conflict_dialog_input.s \
	src/ui/user_menu_dlg.s \
	src/ui/bookmark_dlg.s \
	src/ui/bookmark_dlg_input.s \
	src/ui/search_dialog.s \
	src/ui/search_dialog_input.s \
	src/ui/attr_dialogs.s \
	src/ui/attr_dialogs_input.s \
	src/ui/info_dialog.s \
	src/ui/fuzzy_dialog.s \
	src/ui/img_preview.s \
	src/ui/img_preview_api.s \
	src/ui/du_render.s \
	src/ui/du_progress_dlg.s \
	src/ui/git_render.s \
	src/ui/bulk_rename.s \
	src/ui/bulk_rename_ui.s \
	src/ui/popup_menu.s \
	src/ui/popup_osc52.s \
	src/ui/pkg_dialog.s \
	src/ui/term_pane.s \
	src/ui/term_pane_input.s \
	src/ui/term_keys.s \
	src/ui/syntax.s \
	src/ui/elf_inspect.s \
	src/ui/hex_edit.s \
	src/app/app.s \
	src/app/app_layout.s \
	src/app/app_open.s \
	src/app/app_close_dialog.s \
	src/app/app_cmds.s \
	src/app/app_toggles.s \
	src/app/app_keys.s \
	src/app/app_loop.s \
	src/app/app_choosedir.s \
	src/app/app_task.s \
	src/app/app_task_tick.s \
	src/app/app_events.s \
	src/app/app_view.s \
	src/app/app_attr.s \
	src/app/app_ext.s \
	src/app/app_ext_keys.s \
	src/app/app_du.s \
	src/app/app_arc.s \
	src/app/app_menu.s \
	src/app/app_cmdline.s

# Freestanding C23 modules (docs/HYBRID_PORTABILITY_PLAN.md); migrated leaf-first from the .s list above
C_SRCS := \
	src/core/utf8.c \
	src/core/hash.c \
	src/core/string.c \
	src/core/string_path.c \
	src/core/string_format.c \
	src/core/string_datetime.c \
	src/core/memory.c \
	src/core/oop_rt.c \
	src/core/tmpfile.c \
	src/core/hash_file.c \
	src/core/config.c \
	src/core/config_parse.c \
	src/core/config_load.c \
	src/core/config_expand.c \
	src/core/syscall.c \
	src/core/try_rt.c \
	src/core/mem_prims.c \
	src/fs/inflate.c \
	src/tui/theme.c \
	src/tui/kbd_map.c \
	src/tui/kbd_layout.c \
	src/tui/data_dirs.c \
	src/tui/screen_rect.c \
	src/tui/term_caps.c \
	src/tui/input.c \
	src/tui/input_parse.c \
	src/tui/input_seq.c \
	src/tui/i18n_env.c \
	src/tui/i18n_pack.c \
	src/tui/screen.c \
	src/tui/screen_buffer.c \
	src/tui/screen_text.c \
	src/fs/img_bmp.c \
	src/fs/img_tga.c \
	src/fs/img_pnm.c \
	src/fs/img_gif.c \
	src/fs/img_png.c \
	src/fs/img_jpeg.c \
	src/fs/img_kitty.c \
	src/fs/img_quant.c \
	src/fs/img_sixel.c \
	src/fs/dir_diff.c \
	src/fs/dir_search_match.c \
	src/fs/dir_search.c \
	src/fs/dir_fuzzy.c \
	src/fs/dir_fuzzy_walk.c \
	src/fs/fs_write.c \
	src/fs/du_links.c \
	src/fs/du_cache.c \
	src/fs/du_parallel.c \
	src/fs/disk_usage.c

PAL_SRCS := \
	src/os/$(OS)/$(ARCH)/pal_os.s \
	src/os/$(OS)/$(ARCH)/pal_fault.s \
	src/os/$(OS)/$(ARCH)/pal_uring.s \
	src/os/$(OS)/$(ARCH)/pal_simd.s \
	src/os/$(OS)/$(ARCH)/pal_pty.s \
	src/os/$(OS)/$(ARCH)/pal_thread.s \
	src/os/$(OS)/$(ARCH)/pal_du.s \
	src/os/$(OS)/$(ARCH)/pal_time.s \
	src/os/$(OS)/$(ARCH)/pal_file.s \
	src/os/$(OS)/$(ARCH)/pal_sys_fd.s \
	src/os/$(OS)/$(ARCH)/pal_sys_path.s \
	src/os/$(OS)/$(ARCH)/pal_sys_proc.s \
	src/os/$(OS)/$(ARCH)/pal_sys_mem.s

# Process entry for C-main builds; the asm build still starts in src/main.s (_start) until Stage 4
PAL_START_SRCS := \
	src/os/$(OS)/$(ARCH)/pal_start.s

OBJS := $(patsubst src/%.s,$(BUILD)/%.o,$(SRCS) $(PAL_SRCS)) $(patsubst src/%.c,$(BUILD)/%.o,$(C_SRCS))
INCS := $(wildcard include/*.inc) $(wildcard $(PAL_INC)/*.inc)

.PHONY: all release run test memcheck verify hooks symbols symbols-check clean pal-selftest check-toolchain

all: $(TARGET)

release: ASFLAGS := -I $(PAL_INC) -I include -I $(BUILD)
release: LDFLAGS := -s -z noexecstack --gc-sections
release: clean $(TARGET)

$(TARGET): $(OBJS)
	$(LD) $(LDFLAGS) $(OBJS) -o $@

# Unstripped link of the same objects: the binary-level audits (audit_live_regs.py) need the symbol table
$(BUILD)/duop.sym: $(OBJS)
	$(LD) -z noexecstack --gc-sections $(OBJS) -o $@

$(VER_INC): VERSION
	@mkdir -p $(BUILD)
	@printf '.macro DUOP_VER_ASCII\n    .ascii "$(VERSION)"\n.endm\n.macro DUOP_VER_ASCIZ\n    .asciz "$(VERSION)"\n.endm\n' > $@

$(BUILD)/version.h: VERSION
	@mkdir -p $(BUILD)
	@printf '#pragma once\n#define DUOP_VERSION "$(VERSION)"\n' > $@

$(BUILD)/%.o: src/%.s $(INCS) $(VER_INC)
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/%.o: src/%.c $(wildcard include/*.h) | $(BUILD)/version.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

# PAL walking skeleton: C self-test linked with the PAL of the selected ARCH (qemu-aarch64 runs the arm64 one).
# Objects live in build_selftest/<arch>/ so they never leak into the main build/ tree that tests glob.
ST      := build_selftest/$(ARCH)
ST_OBJS := $(patsubst src/%.s,$(ST)/%.o,$(PAL_SRCS) $(PAL_START_SRCS)) $(ST)/pal_selftest/pal_selftest.o $(ST)/pal_selftest/mem.o
SELFTEST := $(ST)/selftest

$(ST)/%.o: src/%.s $(INCS)
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) $< -o $@

$(ST)/pal_selftest/%.o: tools/pal_selftest/%.c include/duop_abi.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(SELFTEST): $(ST_OBJS)
	$(LD) $(LDFLAGS) $(ST_OBJS) -o $@

pal-selftest: $(SELFTEST)
ifeq ($(ARCH),aarch64)
	qemu-aarch64 $(SELFTEST)
else
	$(SELFTEST)
endif

check-toolchain:
	@$(CC) --version | head -1
	@$(AS) --version | head -1
	@$(LD) --version | head -1

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	python3 tests/test_pal_architecture.py
	python3 tests/test_abi_cross.py
	python3 tests/test_pal_parity.py
	python3 tests/test_pal_selftest.py
	python3 tests/test_c_utf8.py
	python3 tests/test_c_hash.py
	python3 tests/test_c_inflate.py
	python3 tests/test_c_string.py
	python3 tests/test_c_syscall.py
	python3 tests/test_c_memory.py
	python3 tests/test_c_core_files.py
	python3 tests/test_c_config_expand.py
	python3 tests/test_c_config.py
	python3 tests/test_c_tui_data.py
	python3 tests/test_c_input.py
	python3 tests/test_c_i18n.py
	python3 tests/test_c_screen.py
	python3 tests/test_c_img.py
	python3 tests/test_c_img_out.py
	python3 tests/test_c_fs_small.py
	python3 tests/test_c_dir_search.py
	python3 tests/test_c_dir_fuzzy.py
	python3 tests/test_c_du_tables.py
	python3 tests/test_c_du_walk.py
	python3 tests/test_c_du_populate.py
	python3 tests/test_abi_layouts.py
	python3 tests/test_pty.py
	python3 tests/test_fs_reliability.py
	python3 tests/test_performance_dir.py
	python3 tests/test_bg_tasks.py
	python3 tests/test_fastpath.py
	python3 tests/test_choosedir.py
	python3 tests/test_config_usermenu.py
	python3 tests/test_nav_tabs.py
	python3 tests/test_search_virtual.py
	python3 tests/test_trash_undo_attr.py
	python3 tests/test_fuzzy_palette.py
	python3 tests/test_img_preview.py
	python3 tests/test_image_formats.py
	python3 tests/test_image_quality.py
	python3 tests/test_security_reliability.py
	python3 tests/test_disk_usage.py
	python3 tests/test_du_progress.py
	python3 tests/test_du_sizes.py
	python3 tests/test_archive_vfs.py
	python3 tests/test_git_status.py
	python3 tests/test_bulk_rename.py
	python3 tests/test_viewer_pro.py
	python3 tests/test_diff_menu_clip.py
	python3 tests/test_term_pane.py
	python3 tests/test_nav_viewer.py
	python3 tests/test_event_loop.py
	python3 tests/test_kbd_layout.py
	python3 tests/test_help_instruction.py
	python3 tests/test_lang_packs.py
	python3 tests/test_ui_visual.py
	python3 tests/test_pkg_manager.py
	python3 tests/test_pkg_extensions.py
	python3 tests/test_pkg_improvements.py
	python3 tests/test_reliability_audit.py
	python3 tests/test_fault_injection.py
	python3 tests/test_smart_runner.py
	python3 tests/test_try_using_and_security.py
	python3 tests/test_security_fixes.py
	python3 tests/test_perf_and_arch_fixes.py
	python3 tests/test_critical_fixes.py
	python3 tests/test_medium_fixes.py
	python3 tests/test_audit_regressions_parsers.py
	python3 tests/test_audit_regressions_mem.py
	python3 tests/test_audit_regressions_io.py
	python3 tests/test_audit_regressions_sig.py
	python3 tests/test_crash_regressions.py
	python3 tests/test_archive_hardening.py
	python3 tests/test_cmd_expand_safety.py
	python3 tests/test_git_trust.py
	python3 tests/test_trash_spec.py
	python3 tests/test_copy_overwrite_atomic.py
	python3 tests/test_config_limits.py
	python3 tests/test_decoder_bounds.py
	python3 tests/test_elf_hardening.py
	python3 tests/test_pane_scrollbar.py
	python3 tests/test_audit_live_regs.py

test-smart: $(TARGET)
	python3 tests/run_smart_tests.py

audit-all: $(TARGET) $(BUILD)/duop.sym
	python3 .agents/skills/duop-reliability-audit/scripts/audit_stack_abi.py
	python3 .agents/skills/duop-reliability-audit/scripts/audit_cfg_stack.py
	python3 .agents/skills/duop-reliability-audit/scripts/audit_syscall_clobber.py
	python3 .agents/skills/duop-reliability-audit/scripts/audit_abi_regs.py
	python3 .agents/skills/duop-reliability-audit/scripts/audit_oop_vtables.py
	python3 .agents/skills/duop-reliability-audit/scripts/audit_fd_eintr.py
	python3 .agents/skills/duop-reliability-audit/scripts/audit_elf_hardening.py $(TARGET)
	python3 .agents/skills/duop-reliability-audit/scripts/audit_live_regs.py $(BUILD)/duop.sym
	python3 .agents/skills/duop-docs-sync/scripts/gen_symbols_catalog.py --check
	gcc -O2 -Wall -Wextra tools/abi_verify.c -o $(BUILD)/abi_verify && $(BUILD)/abi_verify include/os/linux/x86_64/pal_target.inc

symbols:
	python3 .agents/skills/duop-docs-sync/scripts/gen_symbols_catalog.py

symbols-check:
	python3 .agents/skills/duop-docs-sync/scripts/gen_symbols_catalog.py --check

memcheck:
	$(MAKE) MEMCHECK=1
	python3 tests/test_memcheck.py

verify:
	./.agents/skills/duop-pty-verify/scripts/verify_build.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/* .agents/hooks/*.py .agents/skills/*/scripts/*

-include $(shell find $(BUILD) $(ST) -name '*.d' 2>/dev/null)

clean:
	rm -rf $(BUILD) $(TARGET) build_mc build_aarch64 build_selftest duop_memcheck
