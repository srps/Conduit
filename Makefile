.PHONY: build test clean bundle install sim perf help

# Default target
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build all targets (debug)
	swift build

release: ## Build all targets (release, optimized)
	swift build -c release

test: ## Run all tests
	swift test

bundle: ## Build and bundle Conduit.app (debug)
	./bundle-app.sh

bundle-release: ## Build and bundle Conduit.app (release)
	./bundle-app.sh --release

install: ## Build, bundle, and install to /Applications
	./bundle-app.sh --install

install-release: ## Build release, bundle, and install to /Applications
	./bundle-app.sh --release --install

install-helper: ## Install the privileged helper daemon (requires sudo)
	sudo ./install-helper.sh

uninstall-helper: ## Remove the privileged helper daemon (requires sudo)
	sudo ./uninstall-helper.sh

sim: ## Run pm-sim baseline scenario
	swift run pm-sim baseline

sim-all: ## Run all pm-sim scenarios
	swift run pm-sim

perf: ## Run performance gate checks
	bash ./scripts/perf-gate.sh

proxy: ## Run headless proxy on port 3128
	swift run pm-proxy --port 3128 --state-dir /tmp/pm-proxy --status-interval 5

dns: ## Run standalone DNS forwarder on port 5353
	swift run pm-dns --port 5353 --verbose

clean: ## Clean build artifacts
	swift package clean
	rm -rf .build/

resolve: ## Resolve SPM dependencies
	swift package resolve

fmt: ## Format Swift sources (requires swift-format)
	swift-format format --recursive --in-place Sources/ Tests/

lint: ## Lint Swift sources (requires swift-format)
	swift-format lint --recursive Sources/ Tests/
