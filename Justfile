# Run the test suite
test:
	nix develop -c dune exec test/test_manifest.exe

# Build the ash package
build:
	nix build

# Run tests and build
check: test build
