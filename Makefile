# Ninja EMP — developer entrypoints.
#
#   make            # list every target
#   make up         # start PostgreSQL 18 (Docker)
#   make provision  # create both databases + tenant schema + seeds
#   make serve      # run the API + Tenant UI on the host
#   make test       # full PHPUnit suite (unit + functional + end-to-end)
#   make gate       # the whole quality gate, in CI order
#
# Override any variable on the command line, e.g. `make serve NINJA_UI_PORT=9000`.

SHELL := /bin/bash

PHP      ?= php
COMPOSER ?= composer

NINJA_API_PORT ?= 8092
NINJA_UI_PORT  ?= 8091
NINJA_TENANT   ?= tenant_demo

.DEFAULT_GOAL := help

.PHONY: help install up down provision migrate serve serve-api serve-ui \
        test test-unit test-e2e cs cs-fix stan phpmd deptrac infect audit gate

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Setup -------------------------------------------------------------------

install: ## Install dev tooling (composer install)
	$(COMPOSER) install

up: ## Start PostgreSQL 18 in Docker
	docker compose up -d db

down: ## Stop the Docker stack
	docker compose down

provision: ## Create both databases + tenant schema + seeds (destructive)
	bash db/provision.sh $(NINJA_TENANT)

migrate: ## Apply pending migrations to every tenant schema
	bash bin/migrate

# --- Run ---------------------------------------------------------------------

serve: ## Run the API + Tenant UI dev servers together
	bash bin/serve

serve-api: ## Run only the API dev server
	$(PHP) -S 127.0.0.1:$(NINJA_API_PORT) -t app/api/public app/api/public/router.php

serve-ui: ## Run only the Tenant UI dev server
	$(PHP) -S 127.0.0.1:$(NINJA_UI_PORT) -t app/tenant-ui/public app/tenant-ui/public/router.php

# --- Test --------------------------------------------------------------------

test: ## Full PHPUnit suite (unit + functional + end-to-end)
	$(PHP) vendor/bin/phpunit

test-unit: ## Unit suite only
	$(PHP) vendor/bin/phpunit --testsuite unit

test-e2e: ## End-to-end suite only
	$(PHP) vendor/bin/phpunit --testsuite e2e

# --- Quality gate (HANDOFF.md §4, in CI order) -------------------------------

cs: ## Check code style (PSR-12), no changes
	$(PHP) vendor/bin/php-cs-fixer fix --dry-run --diff

cs-fix: ## Auto-fix code style
	$(PHP) vendor/bin/php-cs-fixer fix

stan: ## Static analysis (PHPStan level 10)
	$(PHP) vendor/bin/phpstan analyse --no-progress --memory-limit=1G

phpmd: ## Mess detection (complexity/coupling)
	$(PHP) vendor/bin/phpmd src text phpmd.xml

deptrac: ## Architecture boundaries (bounded contexts)
	$(PHP) vendor/bin/deptrac analyse --no-progress --fail-on-uncovered

infect: ## Mutation testing (primary gate, MSI >= 80%)
	$(PHP) vendor/bin/infection --threads=max --test-framework-options="--testsuite=unit" --only-covering-test-cases

audit: ## Audit runtime dependencies for known vulnerabilities
	$(COMPOSER) audit --no-dev

gate: cs stan phpmd deptrac test infect ## Run the full quality gate in CI order
