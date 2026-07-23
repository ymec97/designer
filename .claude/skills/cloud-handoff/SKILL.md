---
name: cloud-handoff
description: Finish a Claude Code on the web (cloud/Linux) work session on Designer by producing a branch TEST_PLAN.md, pushing it, and printing a Mac-agent handoff (branch name + change context). Use whenever wrapping up implementation work in a cloud session, since the macOS release battery cannot run on the Linux runner.
---

# Cloud handoff workflow

Designer is a macOS/AppKit app. A Claude Code on the web session runs on a
**Linux runner with no Xcode**, so `swift test`, `scripts/build-app.sh`, and the
`--*-test` battery (see `CLAUDE.md` → "Build, test, verify") **cannot run
there**. Every cloud work session must therefore end by handing a Mac-capable
agent everything it needs to verify and fix the change.

**Trigger:** you have finished (or paused) implementation work in a cloud
session and are about to give the user a final answer. Do this before ending the
turn — do not declare the work done without it.

## Steps

1. **Write / refresh `TEST_PLAN.md`** at the repo root on the working branch.
   Overwrite it each session so it always reflects the current change. It must
   contain, in this order:
   - **Header**: branch name, tip commit SHA, base commit, and a one-line note
     that it was authored in cloud and not compiled/run there.
   - **Release battery**: the exact commands from `CLAUDE.md` (with
     `DEVELOPER_DIR` set), and the expected pass signals (`UI-TEST PASS`, etc.),
     including the `--perf-test` "must be plugged in / not Low Power" caveat and
     the `swift package clean` note for phantom link errors.
   - **Automated tests added/changed**: file paths and the new test/step names,
     plus any existing assertion you changed and why.
   - **Manual verification**: per feature and per fix, the concrete steps to
     perform in `build/Designer.app` and the expected result.
   - **Risk areas**: what a compiler/battery might catch that cloud could not
     (uncompiled Swift, defaults, persistence keys, perf-path impact).
   - **If something fails**: fix on the same branch, re-run, push; don't merge
     to `main` until green.

2. **Commit and push** `TEST_PLAN.md` (and any final code) to the **designated
   feature branch** — never `main`. Use `Claude <noreply@anthropic.com>` as
   author/committer (`git config user.email noreply@anthropic.com && git config
   user.name Claude`) so GitHub shows the commit as verified.

3. **Pushing from cloud** (write path is restricted):
   - Try `git push -u origin <branch>` first. The git relay may return **403**
     on `git-receive-pack` even when reads work.
   - If it 403s, push via the **GitHub MCP**: `mcp__github__create_branch`
     (from `main`) then `mcp__github__push_files` (owner/repo `ymec97/designer`,
     the branch, all changed+new files in one commit).
   - If the MCP also 403s with **"Resource not accessible by integration"**, the
     session's GitHub App is read-only — commit locally, tell the user to grant
     Claude's GitHub integration `contents: write` on the repo, and retry once
     they confirm. Do not loop on either path.

4. **Final output to the user** — end the session with a compact handoff block a
   Mac agent can act on directly:
   - **Branch:** `<branch name>` (and tip SHA).
   - **What changed:** the features/fixes, each in a sentence, with the key
     files touched.
   - **How to verify:** "run `TEST_PLAN.md` on a Mac" + the one-line battery
     entry point.
   - **Open risks / anything unverified.**
   - Explicitly state the battery has **not** been run and must pass before merge.

## Done criteria

`TEST_PLAN.md` exists on the branch, is pushed, and the final message names the
branch and summarizes the change well enough that a fresh Mac agent needs no
other context to run the battery and fix failures.
