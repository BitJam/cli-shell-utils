
ROOT        := .

SHELL       := /bin/bash

ME          := cli-shell-utils

MY_SCRIPTS  := choose-console-width cli-package-installer
SCRIPTS     := live-usb-maker live-kernel-updater
LIB_DIR     := $(ROOT)/usr/local/lib/$(ME)
BIN_DIR     := $(ROOT)/usr/local/bin
LOCALE_DIR  := $(ROOT)/usr/share/
DESK_DIR    := $(ROOT)/usr/share/applications/antix
MAN_DIR     := $(ROOT)/usr/share/man/man1
SCRIPTS_ALL := $(addsuffix -all, $(SCRIPTS))

ALL_DIRS   := $(LIB_DIR) $(BIN_DIR) $(LOCALE_DIR) $(DESK_DIR) $(MAN_DIR)

.PHONY: $(SCRIPTS) help all lib $(SCRIPTS_ALL) local-scripts

help:
	@echo "make help                show this help"
	@echo "make all                 install to current directory"
	@echo "make all ROOT=           install to /"
	@echo "make all ROOT=dir        install to directory dir"
	@echo "make lib                 install the lib and aux files"
	@echo "make live-usb-maker      install live-usb-maker"
	@echo "make live-kernel-updater install live-kernel-updater"
	@#echo ""
	@#echo ""

all: $(SCRIPTS) lib local-scripts

local-scripts: | $(BIN_DIR)
	cp $(MY_SCRIPTS) $(BIN_DIR)

lib: | $(LIB_DIR) $(LOCALE_DIR)
	cp -r $(ME).bash bin text-menus $(LIB_DIR)
	cp -r locale $(LOCALE_DIR)

$(SCRIPTS): | $(BIN_DIR) $(DESK_DIR) $(MAN_DIR)
	cp ../$@/$@ $(BIN_DIR)
	test -e ../$@/$@.desktop && cp ../$@/$@.desktop $(DESK_DIR) || true
	test -e ../$@/$@.1 && gzip -c ../$@/$@.1 > $(MAN_DIR)/$@.1.gz || true

live-usb-maker-gui: | $(BIN_DIR)
	cp ../gui-live-usb-maker/live-usb-maker-gui $(BIN_DIR)

$(ALL_DIRS):
	test -d $(ROOT)/
	mkdir -p $@
