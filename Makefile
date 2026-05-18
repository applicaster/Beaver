# Common Beaver tasks (internal codename: LoggerNext — see D21).
# Run `make` (or `make help`) for the list.

PBXPROJ := LoggerNext.xcodeproj/project.pbxproj

.PHONY: help build test release clean version bump ship tag

help:
	@echo "Beaver — common tasks"
	@echo
	@echo "  Build & test"
	@echo "  ────────────"
	@echo "  make build              Build for local development (Debug)"
	@echo "  make test               Run the unit tests"
	@echo "  make clean              Remove build/ and DerivedData"
	@echo
	@echo "  Versioning"
	@echo "  ──────────"
	@echo "  make version            Print current MARKETING_VERSION + build"
	@echo "  make bump VERSION=X.Y.Z Bump version, commit, tag (does NOT push)"
	@echo "  make tag                Re-tag HEAD at the current MARKETING_VERSION"
	@echo
	@echo "  Release"
	@echo "  ───────"
	@echo "  make release            Build, sign, notarize, zip the current version"
	@echo "                          See scripts/.envrc.example for required env vars"
	@echo "  make ship VERSION=X.Y.Z bump + release in one step (push with git push --tags)"

build:
	xcodebuild \
	    -project LoggerNext.xcodeproj \
	    -scheme LoggerNext \
	    -configuration Debug \
	    -destination 'platform=macOS' \
	    build

test:
	xcodebuild test \
	    -project LoggerNext.xcodeproj \
	    -scheme LoggerNext \
	    -destination 'platform=macOS'

release:
	@./scripts/release.sh

clean:
	rm -rf build
	rm -rf ~/Library/Developer/Xcode/DerivedData/LoggerNext-*

# ── Versioning ───────────────────────────────────────────────────────
#
# The Xcode project's MARKETING_VERSION (CFBundleShortVersionString)
# and CURRENT_PROJECT_VERSION (CFBundleVersion) are the single source
# of truth. Bumping happens by sed'ing the pbxproj — works regardless
# of GENERATE_INFOPLIST_FILE settings, unlike `agvtool` which assumes
# a literal Info.plist exists.

version:
	@echo "MARKETING_VERSION       = $$(grep -m1 'MARKETING_VERSION = ' $(PBXPROJ) | sed 's/.*= //; s/;//')"
	@echo "CURRENT_PROJECT_VERSION = $$(grep -m1 'CURRENT_PROJECT_VERSION = ' $(PBXPROJ) | sed 's/.*= //; s/;//')"

bump:
ifndef VERSION
	$(error VERSION is not set. Usage: make bump VERSION=1.2.3)
endif
	@if ! echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$$'; then \
	    echo "❌ VERSION must look like 1.2 or 1.2.3 (got: $(VERSION))"; exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
	    echo "❌ Working tree is dirty. Commit or stash first."; exit 1; \
	fi
	@if git rev-parse "$(VERSION)" >/dev/null 2>&1; then \
	    echo "❌ Tag '$(VERSION)' already exists. Pick a different version or delete the tag."; exit 1; \
	fi
	@echo "▸ Bumping MARKETING_VERSION → $(VERSION)…"
	@sed -i.bak 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $(VERSION);/g' $(PBXPROJ) && rm $(PBXPROJ).bak
	@CURRENT_BUILD=$$(grep -m1 'CURRENT_PROJECT_VERSION = ' $(PBXPROJ) | sed 's/.*= //; s/;//'); \
	NEW_BUILD=$$((CURRENT_BUILD + 1)); \
	echo "▸ Bumping CURRENT_PROJECT_VERSION $$CURRENT_BUILD → $$NEW_BUILD…"; \
	sed -i.bak "s/CURRENT_PROJECT_VERSION = $$CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $$NEW_BUILD;/g" $(PBXPROJ) && rm $(PBXPROJ).bak
	@echo "▸ Committing + tagging…"
	@git add $(PBXPROJ)
	@if [ -f CHANGELOG.md ]; then git add CHANGELOG.md; fi
	@git commit -m "version $(VERSION)"
	@git tag -a $(VERSION) -m "Beaver $(VERSION)"
	@echo
	@echo "✅ Bumped to $(VERSION). Next steps:"
	@echo "   make release        # produces build/Beaver-$(VERSION).zip"
	@echo "   git push && git push --tags"

tag:
	@CURRENT=$$(grep -m1 'MARKETING_VERSION = ' $(PBXPROJ) | sed 's/.*= //; s/;//'); \
	if git rev-parse "$$CURRENT" >/dev/null 2>&1; then \
	    echo "❌ Tag '$$CURRENT' already exists at $$(git rev-list -n1 $$CURRENT)"; exit 1; \
	fi; \
	echo "▸ Tagging HEAD as $$CURRENT…"; \
	git tag -a "$$CURRENT" -m "Beaver $$CURRENT"; \
	echo "✅ Tagged. Push with: git push --tags"

ship: bump release
	@echo
	@echo "🚀 Ready to publish:"
	@echo "   1. Upload build/Beaver-$(VERSION).zip to your distribution location."
	@echo "   2. git push && git push --tags"
