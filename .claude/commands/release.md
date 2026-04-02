# Release keypo-signer + keypo-wallet

Create a new release for the joint keypo-signer + keypo-wallet package.
This is for the unified `v*` release only — not openclaw (which uses `openclaw-v*` tags and has its own version in `keypo-openclaw/Cargo.toml`). Pre-release tags (e.g. v0.4.5-rc1) are not supported.

Arguments: $ARGUMENTS

Parsing: split `$ARGUMENTS` on the first whitespace character. The first token is the version number. Everything after is the description. If either part is empty or `$ARGUMENTS` is blank, prompt the user interactively for both version and description.

All shell commands below assume the working directory is the repository root. Use subshells for directory changes: `(cd keypo-wallet && cargo check)` rather than bare `cd`.

**Shell safety:** `{version}` and `{description}` are template placeholders — replace them with the parsed values. They are NOT shell variables. `{description}` may contain special characters (em dashes, quotes, etc.). It MUST only appear inside single-quoted HEREDOCs (`<<'COMMIT_MSG'`) and plain-text user output. Never interpolate it in double-quoted strings, command arguments, or unquoted shell contexts.

## Steps

### 1. Pre-flight checks

- Verify the current branch is `main` via `git branch --show-current`. If not on main, abort with an error.
- Run `git fetch origin main --tags --prune-tags`.
- Check local is not behind origin: `git merge-base --is-ancestor origin/main HEAD`.
  - If this fails, distinguish the case:
    - Run `git merge-base --is-ancestor HEAD origin/main`. If this succeeds, local is strictly behind → tell user to `git pull --rebase origin main`.
    - If both checks fail, branches have diverged → tell user to resolve manually before releasing.
- Check if local main is ahead of origin: `git log origin/main..HEAD --oneline`. If there is output, show the full log output and warn the user: "Local main is N commits ahead of origin. The following unpushed commits will be pushed alongside the release:\n{log output}\nContinue?" If the user does not confirm, abort.
- Read current version from `keypo-signer/Sources/KeypoCore/Models.swift` (the `keypoVersion` constant) and `keypo-wallet/Cargo.toml` (the `version` field). Confirm they match each other. If they don't, abort.
- Check Cargo.lock: read `keypo-wallet/Cargo.lock` and find the version for the `keypo-wallet` package entry. If it doesn't match the Cargo.toml version, warn: "Cargo.lock version ({lock_ver}) does not match Cargo.toml ({toml_ver}). cargo check will regenerate it." This is informational, not a blocker.
- Run `git status` and check for uncommitted or untracked changes. If any exist, list them and ask the user to confirm they want to proceed (the release commit will contain ONLY the version files — nothing else will be staged). If the user does not confirm, abort.
- Parse or prompt for the new version number and release description.
- Validate that the version matches `^\d+\.\d+\.\d+$`. If not, abort with an error.
- Compare old and new versions numerically (major, then minor, then patch). If the new version is not strictly greater than the current version, abort with an error showing both versions.

### 2. Tag conflict check

- Run `git tag -l v{version}` to check if the tag exists locally.
- Run `git ls-remote --tags origin refs/tags/v{version}` to check the remote.
- If the tag exists in either location, abort and tell the user. Do NOT delete existing tags automatically. Tell them to run `git tag -d v{version} && git push origin :refs/tags/v{version}` if they want to retry.

### 3. Bump versions

Update exactly two source files:
- `keypo-signer/Sources/KeypoCore/Models.swift`: change `keypoVersion = "{old}"` to `keypoVersion = "{new}"`
- `keypo-wallet/Cargo.toml`: change `version = "{old}"` to `version = "{new}"`

Then regenerate the lockfile so it reflects the new version:
```
(cd keypo-wallet && cargo check)
```

Verify the lockfile was updated:
```
git diff --name-only keypo-wallet/Cargo.lock
```
If `Cargo.lock` was not modified, run `(cd keypo-wallet && cargo update -p keypo-wallet)` to update only the workspace root entry.

If `cargo check` fails, revert all changes and abort:
```
git checkout HEAD -- keypo-signer/Sources/KeypoCore/Models.swift keypo-wallet/Cargo.toml keypo-wallet/Cargo.lock
```

### 4. Run tests

Run the test suites against the bumped version to catch failures before CI. Use the same Swift test filter as CI (`release.yml:51`) to exclude vault integration tests that require biometric auth. The filter contains shell metacharacters — preserve the exact single-quoting shown below:

```
(cd keypo-signer && swift test --filter '^(?!.*Vault(Manager|Integration)Tests)')
(cd keypo-wallet && cargo test)
(cd keypo-wallet && cargo clippy --all-targets -- -D warnings)
```

Note: Swift tests may take 3-5 minutes on a cold build. Report build/test progress to the user.

If any test fails, stop and report the failure. Revert the version bumps:
```
git checkout HEAD -- keypo-signer/Sources/KeypoCore/Models.swift keypo-wallet/Cargo.toml keypo-wallet/Cargo.lock
```
Do not proceed.

### 5. Commit

Stage ONLY the version files and lockfile — never use `git add -A` or `git add .`. Before staging, verify no unexpected files are already staged:

```
git diff --cached --name-only  # must be empty; if not, run git reset HEAD first
git add keypo-signer/Sources/KeypoCore/Models.swift keypo-wallet/Cargo.toml keypo-wallet/Cargo.lock
git commit -m "$(cat <<'COMMIT_MSG'
v{version}: {description}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
COMMIT_MSG
)"
```

If the commit fails due to a pre-commit hook, diagnose the failure, fix the issue, re-stage the three files, and create a new commit. Do NOT use `--no-verify` to bypass hooks.

### 6. Final confirmation and push

Show the user: "Ready to push v{version} to origin/main. This will trigger the CI release pipeline (build, code-sign, notarize, Homebrew tap update). Continue?"

If the user does not confirm, tell them: "Commit is local only (no tag yet). You can push manually with `git tag v{version} && git push origin main --tags`, or undo with `git reset HEAD~1`."

If confirmed, create the tag and push both commit and tag atomically:
```
git tag v{version}
git push --atomic origin main v{version}
```

If the push fails, delete the local tag and tell the user to fetch, rebase, and re-run:
```
git tag -d v{version}
```
Then: `git fetch origin main && git rebase origin/main` and re-run `/release`.

If `--atomic` is not supported by the remote, fall back to branch-first: `git push origin main`, then `git push origin v{version}`. If the branch push fails, delete the local tag and abort. If the branch push succeeds but the tag push fails, tell the user: "Commit pushed but tag failed. Push the tag manually: `git push origin v{version}`."

### 7. Verify

- Confirm the tag exists: `git tag -l v{version}`
- Confirm the push landed: `git log --oneline origin/main..HEAD` should be empty
- Tell the user: "Release v{version} tagged and pushed. CI will build, code-sign, notarize, and update the Homebrew tap automatically."
- Show CI status: `gh run list --workflow=release.yml --limit=1`

### Recovery (if CI fails after push)

If the release CI fails after the tag is pushed, do NOT force-push. First identify the version-bump commit:
```
git log --oneline -5
```
Note the SHA of the `v{version}: ...` commit. Then use a clean forward revert:
```
git tag -d v{version}
git push origin :refs/tags/v{version}
gh release delete v{version} --yes 2>/dev/null || true
git revert --no-edit <sha>
git push origin main
```
If the Homebrew formula was already updated by CI, check the tap:
```
gh api repos/keypo-us/homebrew-tap/actions/runs?per_page=1 --jq '.workflow_runs[0].status'
```
If the formula update completed, it will point to a nonexistent release. Manually revert the tap or re-trigger the formula update workflow with the previous version's SHA.

If `git revert` fails due to conflicts, manually restore the previous version strings in both files, stage, and commit.

Note: after recovery, the codebase version reverts to the previous value. Re-running `/release` with the same version will work correctly since the revert commit restores the old version string.
