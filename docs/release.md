# Release

Release builds are Developer-ID signed, notarised, and stapled. Sparkle handles app self-updates separately from `hermes update`, which updates the Hermes agent.

## Signing Notes

- Hardened Runtime is on.
- App Sandbox is off because the app launches external tools.
- Avoid ad-hoc `--deep` re-signing as a release fix. Build products should be signed correctly at archive time.
- CI should verify release artifacts with `codesign --verify --deep --strict --verbose=2` and `xcrun stapler validate`.

## Deferred Decisions

- Sparkle channel selection.
- Inline release notes.
- Mac App Store distribution.
