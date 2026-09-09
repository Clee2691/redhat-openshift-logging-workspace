.PHONY: clone-repos pull-repos remove-repos lint lint-fix help

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

help:
	@echo "Available targets:"
	@echo "  clone-repos    - Clone all workspace repos into this directory"
	@echo "  pull-repos     - Pull latest in all cloned repos"
	@echo "  remove-repos   - Delete all cloned repos to start fresh"
	@echo "  lint           - Run skillsaw linter (Docker)"
	@echo "  lint-fix       - Auto-fix fixable issues"
	@echo "  help           - Show this help"