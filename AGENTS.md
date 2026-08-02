# Agent Guidelines

## Changelog maintenance

`CHANGELOG.md` is a live document. Update its **Unreleased** section in the same change whenever a user-visible feature, fix, behavior change, deprecation, or notable documentation change is made. Write concise outcome-focused entries rather than copying commit messages or implementation details.

When creating a release, move the relevant Unreleased entries into a heading for the exact Git tag and release date (`YYYY-MM-DD`), leave an empty Unreleased section for future work, and update the comparison links at the bottom of the changelog.
