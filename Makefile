VERSION := $(shell cat VERSION)
LDFLAGS := -s -w -X main.version=$(VERSION)
GO ?= go
ARCHES := amd64 arm64

.PHONY: build release test lint clean install

build:
	$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/vole-analyze ./cmd/analyze
	$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/vole-status ./cmd/status

# Static binaries for every supported arch (CGO off), named vole-<tool>-linux-<arch>
release:
	@for a in $(ARCHES); do \
		for t in analyze status; do \
			CGO_ENABLED=0 GOOS=linux GOARCH=$$a $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/vole-$$t-linux-$$a ./cmd/$$t || exit 1; \
		done; \
	done

test:
	bash tests/run.sh

lint:
	shellcheck -x -S warning -e SC2034,SC1090,SC1091,SC2155 vole lib/*.sh lib/core/*.sh install.sh
	$(GO) vet ./...

install:
	./install.sh

clean:
	rm -f bin/vole-*
