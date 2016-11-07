
ROOT       := .

ME         := cli-shell-utils
SCRIPTS    := live-usb-maker live-kernel-updater
MY_DIR     := $(ROOT)/usr/local/lib/$(ME)
BIN_DIR    := $(ROOT)/usr/local/bin
LOCALE_DIR := $(ROOT)/usr/share/
DESK_DIR   := $(ROOT)/usr/share/applications/antix
MAN_DIR    := $(ROOT)/usr/share/man/man1

ALL_DIRS   := $(MY_DIR) $(BIN_DIR) $(LOCALE_DIR) $(DESK_DIR) $(MAN_DIR)

.PHONY: $(SCRIPTS) help install

help:
	@echo "make help               show this help"
	@echo "make install            install to current directory"
	@echo "make install ROOT=      install to /"
	@echo "make install ROOT=dir   install to directory dir"
	@echo ""

install: $(SCRIPTS) | $(MY_DIR) $(LOCALE_DIR)
	cp -r $(ME).bash bin text-menus $(MY_DIR)

$(SCRIPTS): | $(BIN_DIR) $(DESK_DIR) $(MAN_DIR)
	cp ../$@/$@ $(BIN_DIR)
	cp ../$@/$@.desktop $(DESK_DIR)
	gzip -c ../$@/$@.1 > $(MAN_DIR)/$@.1.gz

$(ALL_DIRS):
	mkdir -p $@
