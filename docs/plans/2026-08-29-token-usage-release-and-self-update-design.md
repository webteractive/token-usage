# Token Usage Release and Self-Update Design

## Goal

Give Token Usage the complete release and self-update process used by Zetty,
adapted to this app's SwiftUI menu-bar interface and bundle layout.

## Repository

Create `webteractive/token-usage` as a public GitHub repository and configure it
as this checkout's `origin`. Creating the repository and configuring the remote
do not authorize a push; pushing remains a separate, explicit approval.

## Release workflow

Add local `scripts/package.sh` and `scripts/release.sh` commands. Packaging
generates the Tuist workspace, builds the Release app, places it in a DMG with an
Applications shortcut, and emits a lowercase SHA-256 sidecar. Releasing requires
human-written notes and a clean `main`, runs the tests, bumps
`CFBundleShortVersionString`, commits and pushes the bump, packages the app,
verifies the bundle version and checksum, creates an annotated tag, pushes it,
and publishes both assets in a GitHub release.

The scripts use Token Usage names and paths while retaining Zetty's dry-run,
confirmation, duplicate-tag, branch, authentication, and behind-remote guards.
Builds remain ad-hoc signed, matching Zetty's current process; Developer ID
signing and notarization are outside this change.

## Update architecture

Port Zetty's pure, tested update primitives into `TokenUsageCore`: semantic
version comparison, release-asset selection, checksum verification, and the
generated bundle-swap helper. Adapt the helper's required bundle paths and
backup names to `TokenUsage.app`.

The app layer checks the public GitHub latest-release endpoint for
`webteractive/token-usage`. An observable update controller owns automatic and
manual checks, installation state, progress, and errors. Automatic checks run on
launch and no more than once every six hours. A persisted preference lets users
disable automatic checks without disabling manual checks.

Installation downloads the DMG and checksum, verifies SHA-256, mounts the image,
stages and validates the app bundle, then launches a detached helper. The helper
waits for the current process to exit, moves the old bundle to a backup, copies
and validates the new bundle, restores the backup if anything fails, strips
quarantine, relaunches, and cleans up.

## User interface

The menu-bar dropdown shows an update action only when a newer release exists.
Settings contains the automatic-check toggle and a manual check action. Manual
checks report up-to-date, failure, and available-update outcomes. Installing
shows download and preparation progress, offers release notes, and surfaces
failures instead of silently dismissing them.

## Verification

Port and adapt Zetty's unit tests for semantic versions, asset selection,
checksums, shell quoting, required bundle paths, and rollback behavior. Run the
Swift test suite, generate the Tuist workspace, build the app, validate both
shell scripts, and exercise non-mutating script help where possible. Update the
README so distribution and update behavior match the implementation.
