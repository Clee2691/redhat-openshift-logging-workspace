.PHONY: clone-repos pull-repos remove-repos lint lint-fix help sync-skills lint-symlinks

SKILLSAW_IMAGE := ghcr.io/stbenjam/skillsaw:latest

REPOS = \
	viaq/vector \
	openshift/cluster-logging-operator \
	grafana/loki \
	openshift/eventrouter \
	viaq/log-file-metric-exporter \
	openshift/logging-view-plugin \
	openshift/openshift-docs \
	openshift-eng/openshift-logging-e2e-tests

REPO_DIRS = $(foreach r,$(REPOS),$(notdir $(r)))

# Clone all workspace repos into this directory (HTTPS — works in both local and CI)
# openshift-docs: --single-branch --branch to clone the standalone logging docs branch
clone-repos:
	@for repo in $(REPOS); do \
	  name=$$(basename $$repo); \
	  if [ -d "$$name/.git" ]; then \
	    echo "=== $$name already cloned ==="; \
	  else \
	    flags=""; \
	    if [ "$$name" = "openshift-docs" ]; then flags="--single-branch --branch standalone-logging-docs-main"; fi; \
	    git clone $$flags https://github.com/$$repo.git; \
	  fi; \
	done

# Pull latest changes in all cloned repos
pull-repos:
	@for d in $(REPO_DIRS); do \
	  if [ -d "$$d/.git" ]; then \
	    echo "=== $$d ==="; \
	    git -C "$$d" pull --ff-only; \
	    if [ -f "$$d/.gitmodules" ]; then git -C "$$d" submodule update --init --recursive; fi; \
	  fi; \
	done

# Remove all cloned repos to start fresh (re-clone with make clone-repos)
remove-repos:
	@echo "This will delete all cloned repos. Press Ctrl+C to cancel, Enter to continue."
	@read _confirm
	@for d in $(REPO_DIRS); do \
	  if [ -d "$$d/.git" ]; then echo "Removing $$d..."; rm -rf "$$d"; fi; \
	done
	@echo "Done. Run 'make clone-repos' to re-clone."

lint:
	@docker run --rm -v "$$(pwd):/workspace:Z" $(SKILLSAW_IMAGE) lint --strict $(SKILLSAW_ARGS)

lint-fix:
	@docker run --rm -v "$$(pwd):/workspace:Z" $(SKILLSAW_IMAGE) fix

# Lint the skills symlinks in .agents/skills
lint-symlinks:
	@errors=0; \
	for skill in .claude/skills/*; do \
		[ -e "$$skill" ] || continue; \
		name="$$(basename "$$skill")"; \
		target=".agents/skills/$$name"; \
		if [ ! -L "$$target" ]; then \
			echo "Error: Missing symlink in .agents/skills for '$$name'"; \
			errors=$$((errors + 1)); \
		elif [ ! -e "$$target" ]; then \
			echo "Error: Broken symlink in .agents/skills for '$$name'"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	for link in .agents/skills/*; do \
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

# Sync the skills from .claude/skills to .agents/skills through symlinks
sync-skills:
	@mkdir -p .agents/skills
	@for skill in .claude/skills/*; do \
		[ -e "$$skill" ] || continue; \
		name="$$(basename "$$skill")"; \
		target=".agents/skills/$$name"; \
		if [ ! -e "$$target" ] && [ ! -L "$$target" ]; then \
			ln -s "../../$$skill" "$$target"; \
			echo "Linked: $$name"; \
		else \
			echo "Skipped: $$name (already exists)"; \
		fi; \
	done

help:
	@echo "Available targets:"
	@echo "  clone-repos    - Clone all workspace repos into this directory"
	@echo "  pull-repos     - Pull latest in all cloned repos"
	@echo "  remove-repos   - Delete all cloned repos to start fresh"
	@echo "  lint           - Run skillsaw linter (Docker)"
	@echo "  lint-fix       - Auto-fix fixable issues"
	@echo "  sync-skills    - Sync skills from .claude/skills to .agents/skills"
	@echo "  lint-symlinks  - Lint skills symlinks in .agents/skills"
	@echo "  help           - Show this help"