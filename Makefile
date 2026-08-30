PREFIX ?= /usr/local

.PHONY: all build release run install clean

all: build

build:
	swift build

release:
	swift build -c release

run:
	swift run CanonSync

install: release
	mkdir -p $(PREFIX)/bin
	cp .build/release/CanonSync $(PREFIX)/bin/canonsync
	@echo "✅ Установлено в $(PREFIX)/bin/canonsync"

clean:
	rm -rf .build
