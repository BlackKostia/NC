# Duop — Pure x86-64 GNU Assembler Project Makefile

TARGET  := duop
BUILD   := build
VERSION := $(strip $(shell cat VERSION))
VER_INC := $(BUILD)/version.inc

AS      := as
LD      := ld
ASFLAGS := -I include -I $(BUILD) -g
LDFLAGS :=

SRCS := \
	src/main.s \
	src/core/memory.s \
	src/core/string.s \
	src/core/utf8.s \
	src/core/oop_rt.s \
	src/core/syscall.s \
	src/tui/theme.s \
	src/tui/i18n.s \
	src/tui/screen.s \
	src/tui/input.s \
	src/fs/dir_model.s \
	src/fs/file_ops.s \
	src/ui/header_bar.s \
	src/ui/function_bar.s \
	src/ui/status_bar.s \
	src/ui/file_pane.s \
	src/ui/preview_pane.s \
	src/ui/dialogs.s \
	src/app/app.s

OBJS := $(patsubst src/%.s,$(BUILD)/%.o,$(SRCS))
INCS := $(wildcard include/*.inc)

.PHONY: all release run test verify hooks clean

all: $(TARGET)

release: ASFLAGS := -I include -I $(BUILD)
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
	python3 tests/test_pty.py

verify:
	./.agents/skills/duop-pty-verify/scripts/verify_build.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/* .agents/hooks/*.py .agents/skills/*/scripts/*

clean:
	rm -rf $(BUILD) $(TARGET)
