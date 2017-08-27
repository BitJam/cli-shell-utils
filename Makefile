
ROOT        := .

SHELL       := /bin/bash

ME          := cli-shell-utils

APT_WRAPPER := cli-package-installer

DEB_ROOT    := debian

SCRIPTS     := live-usb-maker live-kernel-updater
LIB_DIR     := $(ROOT)/usr/local/lib/$(ME)
BIN_DIR     := $(ROOT)/usr/local/bin
LOCALE_DIR  := $(ROOT)/usr/share/locale
DESK_DIR    := $(ROOT)/usr/share/applications/antix
MAN_DIR     := $(ROOT)/usr/local/share/man/man1
SCRIPTS_ALL := $(addsuffix -all, $(SCRIPTS))

ALL_DIRS   := $(LIB_DIR) $(BIN_DIR) $(LOCALE_DIR) $(DESK_DIR) $(MAN_DIR)

.PHONY: $(SCRIPTS) dd-live-usb help all lib $(SCRIPTS_ALL) debian clean locales

help:
	@echo "make help                show this help"
	@echo "make debian              Install under $(DEB_ROOT)/ directory"
	@echo "                          delete scripts that are packaaged elsewhere"
	@echo "make clean               remove the $(DEB_ROOT)/ directory"
	@echo "make all                 install to current directory"
	@echo "make all ROOT=           install to /"
	@echo "make all ROOT=dir        install to directory dir"
	@echo "make lib                 install the lib and aux files"
	@echo "make live-usb-maker      install live-usb-maker"
	@echo "make live-kernel-updater install live-kernel-updater"
	@#echo ""
	@#echo ""

all: $(SCRIPTS) dd-live-usb lib locales

debian:
	mkdir -p $(DEB_ROOT)
	make all ROOT=$(DEB_ROOT)
	rm -f $(DEB_ROOT)/$(LIB_DIR)/bin/copy-initrd-*

clean:
	test -d $(DEB_ROOT) && rm -r $(DEB_ROOT) || true

lib: | $(LIB_DIR) $(LOCALE_DIR)
	cp -r $(ME).bash bin text-menus $(LIB_DIR)

locales: | $(LOCALE_DIR)
	cp -r locale/* $(LOCALE_DIR)

dd-live-usb: | $(BIN_DIR)
	cp ../live-usb-maker/dd-live-usb $(BIN_DIR)

$(SCRIPTS): | $(BIN_DIR) $(DESK_DIR) $(MAN_DIR)
	cp ../$@/$@ $(BIN_DIR)
	test -e ../$@/$@.desktop && cp ../$@/$@.desktop $(DESK_DIR) || true
	test -e ../$@/$@.1 && gzip -c ../$@/$@.1 > $(MAN_DIR)/$@.1.gz || true

$(ALL_DIRS):
	test -d $(ROOT)/
	mkdir -p $@
