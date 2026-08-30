PREFIX ?= /usr/local

.PHONY: all build release run stream web-stream install clean

all: build

build:
	swift build

release:
	swift build -c release

run:
	swift run CanonSync

stream:
	swift run CanonSync --stream

web-stream:
	./webstream.py

install: release
	mkdir -p $(PREFIX)/bin
	cp .build/release/CanonSync $(PREFIX)/bin/canonsync
	@echo "✅ Установлено в $(PREFIX)/bin/canonsync"

clean:
	rm -rf .build
