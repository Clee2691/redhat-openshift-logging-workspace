.PHONY: clone-repos pull-repos remove-repos lint lint-fix help sync-skills lint-symlinks

SKILLSAW_IMAGE   ?= ghcr.io/stbenjam/skillsaw:latest
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null || echo docker)
GIT_BASE_URL     ?= git@github.com:
SKILLS_SRC_DIR   ?= .claude/skills
SKILLS_DST_DIR   ?= .agents/skills

REPOS = \
    viaq/vector \
    openshift/cluster-logging-operator \
    grafana/loki \
    openshift/eventrouter \
    viaq/log-file-metric-exporter \
    openshift/logging-view-plugin \
    openshift/openshift-docs \
    openshift-eng/openshift-logging-e2e-tests \
    openshift/release

REPO_DIRS = $(foreach r,$(REPOS),$(notdir $(r)))

## clone-repos: Clone all workspace repos into this directory
clone-repos:
	@for repo in $(REPOS); do \
		name=$$(basename $$repo); \
		if [ -d "$$name/.git" ]; then \
			echo "=== $$name already cloned ==="; \
		else \
			flags=""; \
			if [ "$$name" = "openshift-docs" ]; then flags="--single-branch --branch standalone-logging-docs-main"; fi; \
			git clone $$flags $(GIT_BASE_URL)$$repo.git; \
		fi; \
	done

## pull-repos: Pull latest changes in all cloned repos
pull-repos:
	@for d in $(REPO_DIRS); do \
		if [ -d "$$d/.git" ]; then \
			echo "=== $$d ==="; \
			git -C "$$d" pull --ff-only; \
			if [ -f "$$d/.gitmodules" ]; then git -C "$$d" submodule update --init --recursive; fi; \
		fi; \
	done

## remove-repos: Delete all cloned repos to start fresh
remove-repos:
	@echo "This will delete all cloned repos. Press Ctrl+C to cancel, Enter to continue."
	@read _confirm
	@for d in $(REPO_DIRS); do \
		if [ -d "$$d/.git" ]; then echo "Removing $$d..."; rm -rf "$$d"; fi; \
	done
	@echo "Done. Run 'make clone-repos' to re-clone."

## lint: Run skillsaw linter (Docker or Podman)
lint:
	@$(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/workspace:Z" $(SKILLSAW_IMAGE) lint --strict $(SKILLSAW_ARGS)

## lint-fix: Auto-fix fixable issues
lint-fix:
	@$(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/workspace:Z" $(SKILLSAW_IMAGE) fix

## lint-symlinks: Lint skills symlinks in target directory
lint-symlinks:
	@errors=0; \
	for skill in $(SKILLS_SRC_DIR)/*; do \
		[ -e "$$skill" ] || continue; \
		name="$$(basename "$$skill")"; \
		target="$(SKILLS_DST_DIR)/$$name"; \
		if [ ! -L "$$target" ]; then \
			echo "Error: Missing symlink in $(SKILLS_DST_DIR) for '$$name'"; \
			errors=$$((errors + 1)); \
		elif [ ! -e "$$target" ]; then \
			echo "Error: Broken symlink in $(SKILLS_DST_DIR) for '$$name'"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	for link in $(SKILLS_DST_DIR)/*; do \
		if [ -L "$$link" ] && [ ! -e "$$link" ]; then \
			echo "Error: Dangling symlink found at '$$link'"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -gt 0 ]; then \
		echo "Found $$errors skill symlink issue(s)."; \
		exit 1; \
	fi; \
	echo "All skill symlinks are present and valid."

## sync-skills: Sync skills from source to destination via symlinks
sync-skills:
	@mkdir -p $(SKILLS_DST_DIR)
	@for skill in $(SKILLS_SRC_DIR)/*; do \
		[ -e "$$skill" ] || continue; \
		name="$$(basename "$$skill")"; \
		target="$(SKILLS_DST_DIR)/$$name"; \
		if [ ! -e "$$target" ] && [ ! -L "$$target" ]; then \
			ln -s "../../$$skill" "$$target"; \
			echo "Linked: $$name"; \
		else \
			echo "Skipped: $$name (already exists)"; \
		fi; \
	done

## help: Show available targets and descriptions
help:
	@echo "Available targets:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':' | sed 's/^/  /'