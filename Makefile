.PHONY: proto-gen android-build macos-build macos-resolve clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

proto-gen: ## Generate proto files for both platforms
	./scripts/generate-protos.sh

android-build: proto-gen ## Build Android debug APK
	cd android && ./gradlew assembleDebug

macos-resolve: ## Resolve macOS SPM dependencies
	cd macos/AndroidContinuity && swift package resolve

macos-build: proto-gen ## Build macOS app
	cd macos/AndroidContinuity && swift build

clean: ## Clean all build artifacts
	cd android && ./gradlew clean 2>/dev/null || true
	cd macos/AndroidContinuity && swift package clean 2>/dev/null || true
	rm -rf macos/AndroidContinuity/Sources/Generated/*.swift
	rm -rf android/app/src/main/proto/continuity/
