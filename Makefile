SHELL := /bin/sh

SCOPE := all
ifneq ($(filter macos,$(MAKECMDGOALS)),)
SCOPE := macos
endif
ifneq ($(filter common,$(MAKECMDGOALS)),)
SCOPE := common
endif
ifneq ($(filter server,$(MAKECMDGOALS)),)
SCOPE := server
endif
ifneq ($(filter all,$(MAKECMDGOALS)),)
SCOPE := all
endif

.DEFAULT_GOAL := help

.PHONY: help macos common server all build test run app install package doctor check \
	common-build common-test common-run common-app common-install \
	macos-build macos-test macos-run macos-app macos-install \
	server-build server-test server-run server-package server-doctor \
	all-build all-test all-run all-app all-install

help:
	@echo "Sonora monorepo commands"
	@echo ""
	@echo "  make macos build     Build the macOS app"
	@echo "  make macos test      Test the macOS app"
	@echo "  make macos run       Run the macOS app"
	@echo "  make macos app       Create macos/dist/Sonora.app"
	@echo "  make macos install   Install the app in ~/Applications"
	@echo "  make common build    Build the shared library"
	@echo "  make common test     Test the shared library"
	@echo "  make server build    Build the LAN sync hub"
	@echo "  make server test     Test protocol, core, store, and daemon"
	@echo "  make server run      Run the configured hub"
	@echo "  make server package  Package standalone distribution assets"
	@echo "  make server doctor   Report toolchain, targets, and signing tools"
	@echo "  make all build       Build every package"
	@echo "  make all test        Test every package"
	@echo "  make all run         Build common and run the macOS app"
	@echo "  make check           Run all tests and architecture checks"
	@echo ""
	@echo "Hyphenated aliases such as 'make macos-build' also work."

macos common server all:
	@:

build:
	@$(MAKE) $(SCOPE)-build

test:
	@$(MAKE) $(SCOPE)-test

run:
	@$(MAKE) $(SCOPE)-run

app:
	@$(MAKE) $(SCOPE)-app

install:
	@$(MAKE) $(SCOPE)-install

package:
	@$(MAKE) $(SCOPE)-package

doctor:
	@$(MAKE) $(SCOPE)-doctor

common-build:
	swift build --package-path common

common-test:
	swift test --package-path common

common-run: common-build
	@echo "SonoraCommon is a library; there is no standalone process to run."

common-app: common-build
	@echo "SonoraCommon is a library; there is no app bundle to create."

common-install: common-build
	@echo "SonoraCommon is a library; there is no app to install."

macos-build:
	swift build --package-path macos

macos-test:
	swift test --package-path macos

macos-run:
	swift run --package-path macos Sonora

macos-app:
	./macos/scripts/build-app.sh

macos-install:
	./macos/scripts/install-app.sh

server-build:
	cargo build --manifest-path server/Cargo.toml --workspace

server-test:
	cargo test --manifest-path server/Cargo.toml --workspace

server-run:
	cargo run --manifest-path server/Cargo.toml -p sonora-server -- serve

server-package:
	cargo build --manifest-path server/Cargo.toml -p sonora-server --release
	./server/scripts/package.sh

server-doctor:
	./server/scripts/doctor.sh

all-build: common-build macos-build server-build

all-test: common-test macos-test server-test

all-run: common-build macos-run

all-app: common-build macos-app

all-install: common-build macos-install

check: all-test
	./macos/scripts/check-architecture.sh
	./macos/scripts/check-library-health-architecture.sh
	cargo fmt --manifest-path server/Cargo.toml --all -- --check
	cargo clippy --manifest-path server/Cargo.toml --workspace --all-targets -- -D warnings
