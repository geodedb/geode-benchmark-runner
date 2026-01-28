# Graphbench Benchmark Runner Makefile
# SPDX-License-Identifier: MIT
# Copyright (c) 2024-2026 CodePros

.PHONY: all build build-release test clean help
.PHONY: pre-commit pre-commit-install pre-commit-update pre-commit-all setup-dev
.PHONY: fmt fmt-check run validate

# Default target
all: build test

# =============================================================================
# Build targets
# =============================================================================

# Debug build
build:
	zig build

# Release build (optimized)
build-release:
	zig build -Doptimize=ReleaseFast

# Run unit tests
test:
	zig build test

# Format all Zig files
fmt:
	zig fmt src/ build.zig

# Check formatting without modifying
fmt-check:
	zig fmt --check src/ build.zig

# Clean build artifacts
clean:
	rm -rf zig-out/ .zig-cache/

# =============================================================================
# Run targets
# =============================================================================

# Run benchmark (requires config file)
run:
	@if [ -z "$(CONFIG)" ]; then \
		echo "Usage: make run CONFIG=<config.json> [OUT=<output_dir>]"; \
		exit 1; \
	fi
	./zig-out/bin/graphbench run --config $(CONFIG) --out $(or $(OUT),./results/)

# Validate configuration
validate:
	@if [ -z "$(CONFIG)" ]; then \
		echo "Usage: make validate CONFIG=<config.json>"; \
		exit 1; \
	fi
	./zig-out/bin/graphbench validate --config $(CONFIG)

# =============================================================================
# Pre-commit hooks
# =============================================================================

# Run pre-commit on all files
pre-commit:
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo "pre-commit not installed. Run 'make pre-commit-install' first."; \
		exit 1; \
	fi

# Install pre-commit hooks
pre-commit-install:
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo "Installing pre-commit..."; \
		pip3 install --user pre-commit || pip install --user pre-commit; \
	fi
	@echo "Installing pre-commit hooks..."
	pre-commit install
	pre-commit install --hook-type commit-msg
	pre-commit install --hook-type pre-push
	@echo "✓ Pre-commit hooks installed"

# Update pre-commit hooks to latest versions
pre-commit-update:
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit autoupdate; \
	else \
		echo "pre-commit not installed. Run 'make pre-commit-install' first."; \
		exit 1; \
	fi

# Run all pre-commit hooks including manual stages
pre-commit-all:
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files --hook-stage pre-commit && \
		pre-commit run --all-files --hook-stage pre-push; \
	else \
		echo "pre-commit not installed. Run 'make pre-commit-install' first."; \
		exit 1; \
	fi

# Full development environment setup
setup-dev: pre-commit-install
	@echo "Installing Python development tools..."
	pip3 install --user ruff commitizen || pip install --user ruff commitizen
	@echo ""
	@echo "✓ Development environment ready!"
	@echo ""
	@echo "Quick start:"
	@echo "  make build      - Build the benchmark runner"
	@echo "  make test       - Run unit tests"
	@echo "  make pre-commit - Run all pre-commit checks"

# =============================================================================
# Help
# =============================================================================

help:
	@echo "Graphbench Benchmark Runner"
	@echo ""
	@echo "Build targets:"
	@echo "  make build         - Debug build"
	@echo "  make build-release - Release build (optimized)"
	@echo "  make test          - Run unit tests"
	@echo "  make clean         - Clean build artifacts"
	@echo ""
	@echo "Code quality:"
	@echo "  make fmt           - Format all Zig files"
	@echo "  make fmt-check     - Check formatting"
	@echo "  make pre-commit    - Run pre-commit on all files"
	@echo ""
	@echo "Development setup:"
	@echo "  make setup-dev         - Full development environment setup"
	@echo "  make pre-commit-install - Install pre-commit hooks"
	@echo "  make pre-commit-update  - Update hooks to latest versions"
	@echo ""
	@echo "Run targets:"
	@echo "  make run CONFIG=<file> [OUT=<dir>] - Run benchmark"
	@echo "  make validate CONFIG=<file>        - Validate config"
