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
ASFLAGS := -I $(PAL_INC) -I include -I $(BUILD) -g --strip-local-absolute
LDFLAGS :=

ifeq ($(MEMCHECK),1)
TARGET  := duop_memcheck
BUILD   := build_mc
ASFLAGS += --defsym MEMCHECK=1
endif

VER_INC := $(BUILD)/version.inc

SRCS := \
	src/main.s \
	src/core/memory.s \
	src/core/memcheck.s \
	src/core/string.s \
	src/core/string_format.s \
	src/core/string_datetime.s \
	src/core/string_path.s \
	src/core/utf8.s \
	src/core/oop_rt.s \
	src/core/syscall.s \
	src/core/config.s \
	src/core/config_parse.s \
	src/core/config_load.s \
	src/core/config_expand.s \
	src/core/hash.s \
	src/core/hash_file.s \
	src/tui/theme.s \
	src/tui/i18n.s \
	src/tui/i18n_env.s \
	src/tui/screen.s \
	src/tui/screen_buffer.s \
	src/tui/screen_text.s \
	src/tui/screen_out.s \
	src/tui/input.s \
	src/tui/term_caps.s \
	src/tui/screen_rect.s \
	src/tui/input_parse.s \
	src/tui/kbd_map.s \
	src/tui/kbd_layout.s \
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
	src/fs/img_kitty.s \
	src/fs/img_quant.s \
	src/fs/img_sixel.s \
	src/fs/img_png.s \
	src/fs/img_png_px.s \
	src/fs/img_bmp.s \
	src/fs/img_pnm.s \
	src/fs/img_tga.s \
	src/fs/img_gif.s \
	src/fs/img_gif_lzw.s \
	src/fs/img_jpeg.s \
	src/fs/img_jpeg_frame.s \
	src/fs/img_jpeg_scan.s \
	src/fs/img_jpeg_bits.s \
	src/fs/img_jpeg_idct.s \
	src/fs/nav_state.s \
	src/fs/nav_state_history.s \
	src/fs/nav_state_bookmarks.s \
	src/fs/nav_state_frecency.s \
	src/fs/dir_search_match.s \
	src/fs/dir_search.s \
	src/fs/dir_search_walk.s \
	src/fs/dir_search_reset.s \
	src/fs/dir_fuzzy.s \
	src/fs/dir_fuzzy_walk.s \
	src/fs/dir_diff.s \
	src/fs/inflate.s \
	src/fs/inflate_api.s \
	src/fs/disk_usage.s \
	src/fs/archive_vfs.s \
	src/fs/archive_extract.s \
	src/fs/git_status.s \
	src/fs/git_status_query.s \
	src/fs/trash_undo.s \
	src/fs/trash_undo_ops.s \
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
	src/ui/git_render.s \
	src/ui/bulk_rename.s \
	src/ui/bulk_rename_ui.s \
	src/ui/popup_menu.s \
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
	src/app/app_arc.s \
	src/app/app_menu.s

PAL_SRCS := \
	src/os/$(OS)/$(ARCH)/pal_os.s \
	src/os/$(OS)/$(ARCH)/pal_uring.s \
	src/os/$(OS)/$(ARCH)/pal_simd.s \
	src/os/$(OS)/$(ARCH)/pal_pty.s

OBJS := $(patsubst src/%.s,$(BUILD)/%.o,$(SRCS) $(PAL_SRCS))
INCS := $(wildcard include/*.inc) $(wildcard $(PAL_INC)/*.inc)

.PHONY: all release run test memcheck verify hooks clean

all: $(TARGET)

release: ASFLAGS := -I $(PAL_INC) -I include -I $(BUILD)
release: LDFLAGS := -s
release: clean $(TARGET)

$(TARGET): $(OBJS)
	$(LD) $(LDFLAGS) $(OBJS) -o $@

$(VER_INC): VERSION
	@mkdir -p $(BUILD)
	@printf '.macro DUOP_VER_ASCII\n    .ascii "$(VERSION)"\n.endm\n.macro DUOP_VER_ASCIZ\n    .asciz "$(VERSION)"\n.endm\n' > $@

$(BUILD)/%.o: src/%.s $(INCS) $(VER_INC)
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) $< -o $@

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	python3 tests/test_pal_architecture.py
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
	python3 tests/test_disk_usage.py
	python3 tests/test_archive_vfs.py
	python3 tests/test_git_status.py
	python3 tests/test_bulk_rename.py
	python3 tests/test_viewer_pro.py
	python3 tests/test_diff_menu_clip.py
	python3 tests/test_term_pane.py
	python3 tests/test_nav_viewer.py
	python3 tests/test_event_loop.py
	python3 tests/test_kbd_layout.py

memcheck:
	$(MAKE) MEMCHECK=1
	python3 tests/test_memcheck.py

verify:
	./.agents/skills/duop-pty-verify/scripts/verify_build.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/* .agents/hooks/*.py .agents/skills/*/scripts/*

clean:
	rm -rf $(BUILD) $(TARGET) build_mc duop_memcheck
