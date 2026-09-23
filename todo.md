# Structural Legibility Pass — `app/` → `apps/`, resolve `ui/`, cross-platform runner

## 0. Reconnaissance
- [x] Inventory `app/` and `ui/` contents
- [x] Grep every `app/` reference across code, config, scripts, docs
- [x] Decide fate of stray `ui/` prototype (→ `docs/prototypes/vendor-portal/`)

## 1. Rename `app/` → `apps/`
- [x] `git mv app apps`
- [x] Update `composer.json` autoload PSR-4
- [x] Update `Makefile` (rewritten as thin wrapper)
- [x] Update `phpstan.neon` (paths + excludePaths)
- [x] Update `deptrac.yaml`
- [x] Update `.php-cs-fixer.dist.php` finder
- [x] Update `tests/E2E/*` document roots
- [x] Update in-repo READMEs and docs references
- [x] `composer dump-autoload`

## 2. Resolve stray `ui/`
- [x] Move to `docs/prototypes/vendor-portal/`; update its README + references

## 3. Cross-platform runner (no `make` on Windows)
- [x] Add `bin/ninja` (pure-PHP task runner)
- [x] Remove `bin/serve`, `bin/migrate` (superseded)
- [x] Rewrite `Makefile` as optional wrapper over `bin/ninja`

## 4. Entry-point documentation
- [x] Root README: two-apps table (document roots + ports) + commands
- [x] Per-app READMEs (`apps/api/README.md`, `apps/tenant-ui/README.md`)

## 5. Verify
- [x] CS green (0/186)
- [x] PHPStan L10 green
- [x] PHPMD green
- [x] Deptrac green (0 uncovered)
- [x] PHPUnit 49 tests green (functional DBAL ran on live PG)
- [x] SQL suites 241 assertions green
- [x] Both apps boot via `php bin/ninja serve` (UI 200, API health 200, /api/me 401)
- [x] Infection MSI 81% / Covered MSI 83% (1,487 killed / 1,836)

## 6. Ship
- [ ] Commit and push to `main`
