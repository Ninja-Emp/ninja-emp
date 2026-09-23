# Ninja EMP — optional convenience wrapper around `php bin/ninja`.
#
# The canonical entrypoint is `php bin/ninja <task>`, which is pure PHP and runs
# on Windows, macOS and Linux with no extra tooling. This Makefile exists only
# for people who already have `make` and prefer it; every target is a one-line
# delegation, so the two can never drift.
#
#   make            # list every target
#   make serve      # run the API + Tenant UI on the host
#   make gate       # the whole quality gate, in CI order

PHP ?= php

.DEFAULT_GOAL := help

.PHONY: help install up down provision migrate serve serve-api serve-ui \
        test test-unit test-e2e cs cs-fix stan phpmd deptrac infect audit gate

help: ## Show this help
	@$(PHP) bin/ninja help

install: ## Install dev tooling (composer install)
	@$(PHP) bin/ninja install

up: ## Start PostgreSQL 18 in Docker
	@$(PHP) bin/ninja up

down: ## Stop the Docker stack
	@$(PHP) bin/ninja down

provision: ## Create both databases + tenant schema + seeds (destructive)
	@$(PHP) bin/ninja provision

migrate: ## Apply pending migrations to every tenant schema
	@$(PHP) bin/ninja migrate

serve: ## Run the API + Tenant UI dev servers together
	@$(PHP) bin/ninja serve

serve-api: ## Run only the API dev server
	@$(PHP) bin/ninja serve-api

serve-ui: ## Run only the Tenant UI dev server
	@$(PHP) bin/ninja serve-ui

test: ## Full PHPUnit suite (unit + functional + end-to-end)
	@$(PHP) bin/ninja test

test-unit: ## Unit suite only
	@$(PHP) bin/ninja test-unit

test-e2e: ## End-to-end suite only
	@$(PHP) bin/ninja test-e2e

cs: ## Check code style (PSR-12), no changes
	@$(PHP) bin/ninja cs

cs-fix: ## Auto-fix code style
	@$(PHP) bin/ninja cs-fix

stan: ## Static analysis (PHPStan level 10)
	@$(PHP) bin/ninja stan

phpmd: ## Mess detection (complexity/coupling)
	@$(PHP) bin/ninja phpmd

deptrac: ## Architecture boundaries (bounded contexts)
	@$(PHP) bin/ninja deptrac

infect: ## Mutation testing (primary gate, MSI >= 80%)
	@$(PHP) bin/ninja infect

audit: ## Audit runtime dependencies for known vulnerabilities
	@$(PHP) bin/ninja audit

gate: ## Run the full quality gate in CI order
	@$(PHP) bin/ninja gate
