.PHONY: help build test test-coverage test-gas deploy-testnet deploy-mainnet deploy-bot-testnet deploy-bot-testnet-mock deploy-bot-mainnet format lint clean install

help:
	@echo "SteadyStake Smart Contracts - Development Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make install          Install dependencies"
	@echo "  make build            Build contracts"
	@echo ""
	@echo "Testing:"
	@echo "  make test             Run all tests"
	@echo "  make test-coverage    Generate coverage report"
	@echo "  make test-gas         Generate gas snapshot"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy-testnet     Deploy to Base Sepolia"
	@echo "  make deploy-mainnet     Deploy to Base Mainnet"
	@echo "  make deploy-bot-testnet Deploy to BOT Chain testnet (968)"
	@echo "  make deploy-bot-testnet-mock Deploy to BOT Chain testnet (968) with MockUSDC"
	@echo "  make deploy-bot-mainnet Deploy to BOT Chain mainnet (677)"
	@echo ""
	@echo "Code Quality:"
	@echo "  make format           Format code"
	@echo "  make lint             Lint code"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean            Clean build artifacts"

install:
	@echo "Installing dependencies..."
	@command -v forge >/dev/null 2>&1 || (echo "Foundry not installed. Installing..." && curl -L https://foundry.paradigm.xyz | bash && foundryup)
	@echo "Dependencies installed"

build:
	@echo "Building contracts..."
	@forge build

test:
	@echo "Running tests..."
	@forge test -v

test-coverage:
	@echo "Generating coverage report..."
	@forge coverage --report lcov
	@echo "Coverage report generated at coverage/lcov.info"

test-gas:
	@echo "Running gas snapshots..."
	@forge snapshot --snap snapshots/.gas-snapshot

format:
	@echo "Formatting code..."
	@forge fmt

lint:
	@echo "Linting code..."
	@solhint 'src/**/*.sol' || true

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf out/
	@rm -rf cache/
	@rm -rf coverage/

deploy-testnet:
	@echo "Deploying to Base Sepolia..."
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set. Set it with: export PRIVATE_KEY=0x..."; \
		exit 1; \
	fi
	@forge script script/Deploy.s.sol:DeployTestnet \
		--rpc-url base_sepolia \
		--broadcast \
		--verify

deploy-mainnet:
	@echo "Deploying to Base Mainnet..."
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set. Set it with: export PRIVATE_KEY=0x..."; \
		exit 1; \
	fi
	@forge script script/Deploy.s.sol:DeployMainnet \
		--rpc-url base \
		--broadcast \
		--verify

deploy-bot-testnet:
	@echo "Deploying to BOT Chain testnet (968)..."
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set. Set it with: export PRIVATE_KEY=0x..."; \
		exit 1; \
	fi
	@forge script script/Deploy.s.sol:DeployBotTestnet \
		--rpc-url bot_testnet \
		--broadcast \
		--legacy \
		--verify --verifier blockscout --verifier-url https://scan.bohr.life/api
	@node scripts/sync-bot-chain.js 968

deploy-bot-testnet-mock:
	@echo "Deploying to BOT Chain testnet (968) with MockUSDC..."
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set. Set it with: export PRIVATE_KEY=0x..."; \
		exit 1; \
	fi
	@forge script script/Deploy.s.sol:DeployBotTestnetWithMockUSDC \
		--rpc-url bot_testnet \
		--broadcast \
		--legacy \
		--verify --verifier blockscout --verifier-url https://scan.bohr.life/api
	@node scripts/sync-bot-chain.js 968

deploy-bot-mainnet:
	@echo "Deploying to BOT Chain mainnet (677)..."
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "Error: PRIVATE_KEY not set. Set it with: export PRIVATE_KEY=0x..."; \
		exit 1; \
	fi
	@forge script script/Deploy.s.sol:DeployBotMainnet \
		--rpc-url bot \
		--broadcast \
		--legacy \
		--verify --verifier blockscout --verifier-url https://scan.botchain.ai/api
	@node scripts/sync-bot-chain.js 677

check:
	@echo "Running verification checks..."
	@forge test
	@forge coverage --report summary
	@forge fmt --check

analyze:
	@echo "Analyzing contract size..."
	@forge build --sizes

docs:
	@echo "Generating documentation..."
	@echo "See README.md and ARCHITECTURE.md for details"

watch:
	@echo "Watching for changes..."
	@forge test --watch

# Development workflow targets
dev: clean build test
	@echo "Development build complete"

ci: build test lint
	@echo "CI checks passed"

audit-ready: clean build test test-coverage
	@echo "Audit preparation complete"
	@echo "Review coverage at coverage/lcov.info"

.DEFAULT_GOAL := help
