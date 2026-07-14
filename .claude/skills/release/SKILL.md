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

## Tag policy

- **Pre-ship (current phase):** the user has NOT yet shipped the first version
  to their work laptop. Until they say they have, every release commit
  **force-retags `v0.1.0`** — do not mint new versions:

  ```sh
  git tag -fa v0.1.0 -m "Designer v0.1.0 — <short summary>"
  ```

- **Post-ship:** once the user says v0.1.0 shipped, that tag is frozen forever.
  From then on each release bumps `VERSION` (SemVer: patch = fixes, minor =
  features, major = breaking board-format changes) and creates a NEW annotated
  tag `v<version>` — never move an existing tag again.
- Tags are annotated (`-a`), named `v<VERSION>`, and placed on the exact commit
  the artifact was built from.
- **Never push** unless the user asks. When they do:
  `git push -u origin main --tags` (`-f` on the tag ref only while pre-ship
  retagging, e.g. `git push origin +refs/tags/v0.1.0`).

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
