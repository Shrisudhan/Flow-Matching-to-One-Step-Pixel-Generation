SHELL := /bin/bash
REPO_ROOT  := $(shell pwd)
PLIST_NAME := com.switchsplat.watch
PLIST_DST  := $(HOME)/Library/LaunchAgents/$(PLIST_NAME).plist

# Ensure tools installed outside of /usr/bin are reachable from non-interactive shells
# (Homebrew, MacTeX, Cursor CLI). Order: TeX → Homebrew → Cursor → existing PATH.
export PATH := /Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/Applications/Cursor.app/Contents/Resources/app/bin:$(PATH)

.PHONY: install uninstall status logs sync watch watch-build build unlock

## Install and start the folder-watch daemon (runs at login automatically).
install:
	@command -v fswatch > /dev/null || brew install fswatch
	@sed "s|REPO_ROOT|$(REPO_ROOT)|g" launchd/$(PLIST_NAME).plist > $(PLIST_DST)
	@launchctl load -w $(PLIST_DST)
	@echo "✓ Installed: $(PLIST_NAME)"
	@echo "  Logs: $(REPO_ROOT)/.git/watch.log"

## Stop and remove the daemon.
uninstall:
	@-launchctl unload -w $(PLIST_DST) 2>/dev/null
	@rm -f $(PLIST_DST)
	@echo "✓ Removed: $(PLIST_NAME)"

## Show daemon status.
status:
	@launchctl list | grep $(PLIST_NAME) || echo "Not running"

## Tail the watcher log.
logs:
	@tail -f $(REPO_ROOT)/.git/watch.log

## Force-remove a stale build lock (use only if you're sure no build is running).
unlock:
	@rmdir "$(BUILD_LOCK)" 2>/dev/null && echo "✓ Lock released" || echo "No lock present"

## Build the PDF locally with latexmk (for preview only — Overleaf owns the committed PDF).
##
## Uses an atomic `mkdir`-based lock so concurrent invocations (e.g. a manual
## `make build` while the `watch-build` daemon is also running) cannot race
## and clobber each other's main.pdf / main.aux / main.bbl outputs.
BUILD_LOCK := $(REPO_ROOT)/.build.lock
build:
	@command -v latexmk > /dev/null || { echo "latexmk not found. Install MacTeX or BasicTeX."; exit 1; }
	@waited=0; while ! mkdir "$(BUILD_LOCK)" 2>/dev/null; do \
	    if [ $$waited -eq 0 ]; then echo "[build] another build is running — waiting…"; fi; \
	    waited=1; sleep 1; \
	  done; \
	  trap 'rmdir "$(BUILD_LOCK)" 2>/dev/null || true' EXIT INT TERM; \
	  echo "[build] Compiling main.tex"; \
	  latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error main.tex \
	    || { echo "[build] FAILED — see main.log"; exit 1; }; \
	  echo "[build] Done → main.pdf"

## Pull, commit pending changes with a descriptive message, and push.
## Excludes *.pdf from staging so we don't fight Overleaf's auto-compiled PDF.
sync:
	@[ -f .git/index.lock ] && { echo "git is busy"; exit 0; } || true
	@cursor agent \
	  --print --yolo --trust \
	  --workspace $(REPO_ROOT) \
	  --output-format stream-json \
	  --stream-partial-output \
	  "Pull latest changes from remote, inspect the git diff, stage all modified files \
EXCEPT *.pdf (the PDF is managed by Overleaf — never stage or commit it), \
write a short descriptive commit message based on what changed, commit, and push to remote. \
If the working tree is already clean (ignoring *.pdf), just pull and push." \
	| python3 -c $$'import sys,json\nfor line in sys.stdin:\n    line=line.strip()\n    if not line: continue\n    try:\n        d=json.loads(line)\n        t=d.get("type","")\n        if t=="assistant":\n            for b in d.get("message",{}).get("content",[]):\n                if b.get("type")=="text": print(b["text"],end="",flush=True)\n        elif t=="tool_call" and d.get("subtype")=="started":\n            desc=d.get("tool_call",{}).get("description","")\n            if desc: print(f"\\n\033[2m[{desc}]\033[0m",end="",flush=True)\n    except: pass\nprint()'

## Run the fswatch watcher in the foreground, rebuilding the PDF on each
## source change WITHOUT auto-syncing git. Use this for local live preview.
watch-build:
	@echo "[watch-build] Monitoring $(REPO_ROOT) (build only — no git sync)"
	@fswatch --latency 5 --one-per-batch --event Updated \
	  --exclude='\.git' --exclude='\.pdf$$' --exclude='\.aux$$' \
	  --exclude='\.log$$' --exclude='\.fls$$' --exclude='\.fdb_latexmk$$' \
	  --exclude='\.bbl$$' --exclude='\.blg$$' --exclude='\.out$$' \
	  --exclude='\.toc$$' --exclude='\.synctex' \
	  $(REPO_ROOT) \
	| while read -r; do \
	    echo "[watch-build] Change detected — building"; \
	    $(MAKE) build || echo "[watch-build] Build failed"; \
	  done

## Run the fswatch watcher in the foreground (used by launchd).
## On each source change: rebuild the PDF locally, then sync git.
watch:
	@echo "[watch] Monitoring $(REPO_ROOT)"
	@fswatch --latency 5 --one-per-batch --event Updated \
	  --exclude='\.git' --exclude='\.pdf$$' --exclude='\.aux$$' \
	  --exclude='\.log$$' --exclude='\.fls$$' --exclude='\.fdb_latexmk$$' \
	  --exclude='\.bbl$$' --exclude='\.blg$$' --exclude='\.out$$' \
	  --exclude='\.toc$$' --exclude='\.synctex' \
	  $(REPO_ROOT) \
	| while read -r; do \
	    echo "[watch] Change detected — building + syncing"; \
	    $(MAKE) build || echo "[watch] Build failed (continuing to sync)"; \
	    $(MAKE) sync && echo "[watch] Done" || echo "[watch] Sync failed"; \
	  done
