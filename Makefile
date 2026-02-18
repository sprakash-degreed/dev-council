# Install to ~/.local by default (no sudo needed)
# Override with: make install PREFIX=/usr/local
PREFIX ?= $(HOME)/.local
SHARE_DIR = $(PREFIX)/share/kannan

.PHONY: install uninstall test check

install:
	@echo "Installing kannan to $(PREFIX)..."
	@mkdir -p $(PREFIX)/bin
	@mkdir -p $(SHARE_DIR)/lib
	@mkdir -p $(SHARE_DIR)/adapters
	@cp lib/*.sh $(SHARE_DIR)/lib/
	@cp adapters/*.sh $(SHARE_DIR)/adapters/
	@cp kannan $(SHARE_DIR)/kannan
	@chmod +x $(SHARE_DIR)/kannan
	@ln -sf $(SHARE_DIR)/kannan $(PREFIX)/bin/kannan
	@echo ""
	@echo "Installed: $(PREFIX)/bin/kannan -> $(SHARE_DIR)/kannan"
	@echo ""
	@if echo "$$PATH" | tr ':' '\n' | grep -qx "$(PREFIX)/bin"; then \
		echo "$(PREFIX)/bin is already in PATH — you're good to go."; \
	else \
		echo "Add $(PREFIX)/bin to your PATH:"; \
		echo ""; \
		echo "  echo 'export PATH=\"$(PREFIX)/bin:\$$PATH\"' >> ~/.bashrc   # bash"; \
		echo "  echo 'export PATH=\"$(PREFIX)/bin:\$$PATH\"' >> ~/.zshrc    # zsh"; \
		echo ""; \
		echo "Then restart your shell or run:"; \
		echo "  export PATH=\"$(PREFIX)/bin:\$$PATH\""; \
	fi

uninstall:
	@rm -f $(PREFIX)/bin/kannan
	@rm -rf $(SHARE_DIR)
	@echo "Uninstalled."

test:
	@echo "Running kannan self-test..."
	@./kannan version
	@echo ""
	@./kannan agent list
	@echo ""
	@echo "All checks passed."

check:
	@echo "Checking dependencies..."
	@bash_ver=$$(bash -c 'echo $$BASH_VERSINFO'); \
		if [ "$$bash_ver" -ge 4 ] 2>/dev/null; then echo "  bash: ok ($$bash_ver)"; \
		else echo "  bash: version 4+ required"; fi
	@command -v jq >/dev/null 2>&1 && echo "  jq: ok" || echo "  jq: MISSING (required)"
	@command -v git >/dev/null 2>&1 && echo "  git: ok" || echo "  git: MISSING (recommended)"
	@command -v gum >/dev/null 2>&1 && echo "  gum: ok" || echo "  gum: not found (optional, for better UI)"
	@echo ""
	@echo "Checking agents..."
	@command -v claude >/dev/null 2>&1 && echo "  claude: ok" || echo "  claude: not found"
	@command -v codex >/dev/null 2>&1 && echo "  codex: ok" || echo "  codex: not found"
	@command -v gemini >/dev/null 2>&1 && echo "  gemini: ok" || echo "  gemini: not found"
	@command -v ollama >/dev/null 2>&1 && echo "  ollama: ok" || echo "  ollama: not found"
