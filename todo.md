# Ninja EMP — Round 5: Durability (Git + backups + local dev)

Goal: make the work durable and reproducible. GitHub = source of truth; sandbox = throwaway build env; local = fast dev. Add schema+data backups committed to the repo, and a downloadable zip.

## A. Git repo + hygiene
- [x] `git init`, set identity, create `.gitignore` (exclude .browser_data, .psiphon_data, outputs, *.zip, backups/*.dump)
- [x] Add `.gitattributes` (normalize line endings; mark *.png binary)
- [ ] Initial commit of all source (db/, docs/, HANDOFF.md, scripts)

## B. Backup system (schema + data → repo folder)
- [x] `scripts/backup.sh`: pg_dump schema-only + data-only + full custom-format for both DBs into `backups/<timestamp>/`
- [x] `scripts/restore.sh`: restore from a backup dir (schema then data)
- [x] `scripts/zip_backup.sh`: produce `dist/ninja-emp-backup-<timestamp>.zip` of latest backup + source
- [x] Run backup; verify restore round-trip (19/20/5/12 green after restore)

## C. GitHub push (user has no repo yet)
- [ ] Provide exact steps + a `scripts/push.sh` helper; ask user for repo URL / token OR use gh if available
- [ ] Document remote setup in README

## D. Local dev (Laragon + PostgreSQL 18)
- [ ] `docs/LOCAL_DEV.md`: install PG 18 alongside Laragon, create DBs, run provision.sh, connect Navicat
- [ ] Note: Laragon ships MySQL, not PG — explicit steps to add PG 18

## E. Next steps roadmap
- [ ] `docs/ROADMAP.md`: Part 5 (POS/Sales/Payments) onward, with sequencing

## F. Validate + deliver
- [ ] Verify backup/restore round-trips; zip exists; commit all; attach + complete
