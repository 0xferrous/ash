# Agent Guidelines

## Changelog maintenance

`CHANGELOG.md` is a live document. Update its **Unreleased** section in the same change whenever a user-visible feature, fix, behavior change, deprecation, or notable documentation change is made. Write concise outcome-focused entries rather than copying commit messages or implementation details.

When creating a release, move the relevant Unreleased entries into a heading for the exact Git tag and release date (`YYYY-MM-DD`), leave an empty Unreleased section for future work, and update the comparison links at the bottom of the changelog.

## Releases

To cut a release `vX.Y.Z` from `main`:

1. Bump the version in `bin/ash/main.ml` (`let version`), `bin/ash/pages.ml` (both HTML footers), and `flake.nix` (both `version = "…"` fields).
2. Update `CHANGELOG.md` as above (`## [vX.Y.Z] - YYYY-MM-DD`, empty `## [Unreleased]`, comparison links).
3. Commit as `release: vX.Y.Z` and verify with `dune build @all` + `dune runtest` and `nix flake check`.
4. Tag the **release commit sha explicitly** (`git tag -a vX.Y.Z -m "ash vX.Y.Z" <sha>`). In this jj colocated repo, git HEAD lags the jj working copy, so a bare `git tag` tags the stale HEAD - always resolve the commit sha first.
5. Push `main` and the tag (`git push <url> <sha>:refs/heads/main` and `git push <url> refs/tags/vX.Y.Z`).
