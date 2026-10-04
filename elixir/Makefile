.PHONY: help all setup deps build fmt fmt-check lint test coverage coverage-clean coverage-partition coverage-transition-fixture \
	h070a-scale coverage-report ci dialyzer e2e isolation-proof verify-codex

MIX ?= mix
COVERAGE_PARTITIONS := 8
COVERAGE_TEST_FILES := $(shell find test -type f -name '*_test.exs' ! -path 'test/symphony_elixir/transition_coordinator_default_path_test.exs' ! -path 'test/symphony_elixir/transition_coordinator_test.exs' | sort)

help:
	@echo "Targets: setup, deps, build, fmt, fmt-check, lint, test, coverage, coverage-partition, coverage-transition-fixture, h070a-scale, coverage-report, dialyzer, e2e, isolation-proof, ci"

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
	$(MAKE) coverage-clean
	@for partition in 1 2 3 4 5 6 7 8; do \
		$(MAKE) coverage-partition PARTITION=$$partition || exit $$?; \
	done
	$(MAKE) coverage-transition-fixture

coverage-clean:
	rm -f cover/*.coverdata

coverage-partition:
	@case "$(PARTITION)" in 1|2|3|4|5|6|7|8) ;; *) echo "PARTITION must be 1 through 8"; exit 2 ;; esac
	@MIX_TEST_PARTITION=$(PARTITION) $(MIX) test $(COVERAGE_TEST_FILES) --partitions $(COVERAGE_PARTITIONS) --cover --exclude h070a_scale

coverage-transition-fixture:
	$(MIX) test test/symphony_elixir/transition_coordinator_default_path_test.exs test/symphony_elixir/transition_coordinator_test.exs --cover --exclude h070a_scale --export-coverage transition-fixture

h070a-scale:
	$(MIX) test --cover --only h070a_scale --export-coverage h070a-scale

coverage-report:
	$(MIX) test.coverage

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
	$(MAKE) h070a-scale
	$(MAKE) coverage-report
	$(MAKE) dialyzer

all: ci isolation-proof
