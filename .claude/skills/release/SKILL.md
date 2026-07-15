---
name: release
description: Tag and release a Designer build — verification battery, versioning rules, dated artifact packaging. Use when asked to cut a release, retag, bump the version, or package the app for installation.
---

# Designer release workflow

How a Designer release is verified, versioned, tagged, and packaged. Follow the
steps in order — never tag or package a build that hasn't passed the battery.

## Source of truth

- **`VERSION`** (repo root) holds the SemVer version, e.g. `0.1.0`. It is the
  ONLY place the version is written by hand. `scripts/build-app.sh` stamps it
  into the app's Info.plist (`CFBundleShortVersionString`), sets the build
  number to `git rev-list --count HEAD`, and embeds `DesignerBuildInfo`
  ("YYYY-MM-DD shortsha"). Verify with `Designer --version`.
- **`CHANGELOG.md`** gets a section per version. Update it in the release
  commit, not after.

## Workflow (post-ship, since 2026-07-15)

v0.1.0 shipped to the work Mac and is FROZEN — existing tags never move.

1. **Branch** for each change set: `git checkout -b fix/<slug>` or
   `feature/<slug>` from main.
2. Commit on the branch (author `Yarden <yarden@c.com>`, no co-author
   trailers); run the verification battery before merging.
3. **Merge to main** with `git merge --no-ff <branch>` (no PRs for now —
   Yarden will say when to switch to a PR-based flow).
4. **Tag when releasing**: bump `VERSION` (SemVer: patch = fixes, minor =
   features, major = breaking board-format changes), update CHANGELOG, then
   `git tag -a v<version> -m "Designer v<version> — <summary>"` on main.
5. Push: `git push origin main v<version>`. Delete the merged branch.

## Verification battery (all must pass before tagging)

Run from the repo root; app binary is `build/Designer.app/Contents/MacOS/Designer`.

```sh
cd DesignerKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # expect: 0 failures
cd .. && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-app.sh
./build/Designer.app/Contents/MacOS/Designer --ui-test                                  # expect: UI-TEST PASS
./build/Designer.app/Contents/MacOS/Designer --smoke-test <scratchpad>/smoke.designerboard  # expect: SMOKE-TEST PASS
caffeinate -u -t 3 && ./build/Designer.app/Contents/MacOS/Designer --perf-test          # expect: PERF-TEST PASS (60Hz floor)
```

Optional when the agent surface changed: `--agent-test` (live MCP end-to-end),
`--catalog-test`. If ANY step fails, fix it first — a release never ships red.

## Release steps

1. Battery (above) is green on the exact tree you're releasing.
2. `CHANGELOG.md` updated; `VERSION` correct for the tag policy phase.
3. Commit everything (release commits end with the standard co-author line).
4. Tag per the policy above.
5. Package the dated artifact:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/package-app.sh
   ```

   Produces `build/Designer-v<VERSION>-<YYYY-MM-DD>.zip` (release config,
   ad-hoc signed). Artifact names are always dated — rebuild the zip whenever
   the tag moves so date, tag, and bits agree.
6. Tell the user the artifact path and, for a new machine, the Gatekeeper
   steps (documented in `scripts/package-app.sh` header): right-click → Open on
   macOS ≤14, System Settings → Privacy & Security → "Open Anyway" on 15+, or
   `xattr -dr com.apple.quarantine Designer.app`.

## Icon regeneration (only when the mark changes)

```sh
swift scripts/generate-icon.swift App/AppIcon.iconset
iconutil -c icns App/AppIcon.iconset -o App/AppIcon.icns
```

The `.iconset` is gitignored; commit the `.icns`.
