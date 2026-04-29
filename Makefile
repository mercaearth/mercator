.PHONY: build test lint check verify fmt clean

build:
	sui move build --path . --build-env testnet

test:
	sui move test --path . --build-env testnet -i 10000000000

lint:
	sui move build --path . --build-env testnet --lint

fmt:
	npx prettier-move --write "sources/**/*.move" "tests/**/*.move"

check:
	npx prettier-move --check "sources/**/*.move" "tests/**/*.move"
	sui move build --path . --lint

verify: check test

clean:
	rm -rf build/
	rm -f Published.toml Move.lock
