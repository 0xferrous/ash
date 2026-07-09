# Run the test suite
test:
	nix develop -c dune exec test/test_manifest.exe

# Format OCaml sources
fmt:
	nix develop -c dune fmt

# Build the ash package
build:
	nix build

# Format, run tests, and build
check: fmt test build
