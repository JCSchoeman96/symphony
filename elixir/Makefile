.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e \
	isolation-proof verify-codex

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, isolation-proof, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover $(if $(EXCLUDE_TAGS),--exclude $(EXCLUDE_TAGS),)

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

verify-codex:
	@command -v codex >/dev/null 2>&1 || { echo "Codex is required for the isolation proof"; exit 1; }
	@codex_version="$$(codex --version)" && \
		test "$$codex_version" = "codex-cli 0.159.3" || { \
			echo "Expected codex-cli 0.159.3, got $$codex_version"; \
			exit 1; \
		}

isolation-proof: verify-codex
	$(MIX) test test/symphony_elixir/runtime_isolation_actual_codex_test.exs test/symphony_elixir/app_server_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci isolation-proof
