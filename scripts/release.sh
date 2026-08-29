#!/bin/sh
# Cuts a Token Usage release: version bump -> commit -> package -> tag -> GitHub release.
#
# Usage:
#   scripts/release.sh --notes <file> (patch | minor | major | X.Y.Z) [--yes] [--dry-run]
set -eu
cd "$(dirname "$0")/.."

REMOTE=origin
BRANCH=main
LEVEL=
NOTES=
ASSUME_YES=0
DRY_RUN=0

die() { printf '%s\n' "error: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: scripts/release.sh --notes <file> (patch | minor | major | X.Y.Z) [--yes] [--dry-run]

  --notes <file>  human-written release notes body (required)
  patch|minor|major|X.Y.Z
                  how to bump CFBundleShortVersionString in Project.swift
  --yes, -y       skip the confirmation prompt
  --dry-run       print the plan and exit without changing anything
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --notes) [ $# -ge 2 ] || die "--notes needs a file"; NOTES=$2; shift 2 ;;
    --notes=*) NOTES=${1#--notes=}; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    patch|minor|major) LEVEL=$1; shift ;;
    [0-9]*.[0-9]*.[0-9]*) LEVEL=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$LEVEL" ] || die "specify patch, minor, major, or an explicit X.Y.Z"
[ -n "$NOTES" ] || die "--notes <file> is required"
[ -f "$NOTES" ] || die "notes file not found: $NOTES"
[ -s "$NOTES" ] || die "notes file is empty: $NOTES"

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

current_branch=$(git rev-parse --abbrev-ref HEAD)
[ "$current_branch" = "$BRANCH" ] || die "on branch '$current_branch', expected '$BRANCH'"

git fetch --quiet "$REMOTE" "$BRANCH"
if [ -n "$(git rev-list "HEAD..$REMOTE/$BRANCH")" ]; then
  die "behind $REMOTE/$BRANCH — pull first"
fi

PLIST_KEY=CFBundleShortVersionString
CURRENT=$(sed -n "s/.*\"$PLIST_KEY\": \"\([0-9][0-9.]*\)\".*/\1/p" Project.swift | head -1)
[ -n "$CURRENT" ] || die "could not read $PLIST_KEY from Project.swift"

case "$LEVEL" in
  patch|minor|major)
    MAJOR=$(printf '%s' "$CURRENT" | cut -d. -f1)
    MINOR=$(printf '%s' "$CURRENT" | cut -d. -f2)
    PATCH=$(printf '%s' "$CURRENT" | cut -d. -f3)
    case "$LEVEL" in
      patch) PATCH=$((PATCH + 1)) ;;
      minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
      major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    esac
    VERSION="$MAJOR.$MINOR.$PATCH"
    ;;
  *) VERSION=$LEVEL ;;
esac
TAG="v$VERSION"

[ "$(git tag -l "$TAG" | wc -l)" -eq 0 ] || die "tag $TAG already exists locally"
[ "$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG" | wc -l)" -eq 0 ] \
  || die "tag $TAG already exists on $REMOTE"

DMG="dist/TokenUsage-$VERSION.dmg"
SHA="$DMG.sha256"

cat <<PLAN
Release plan
  version      $CURRENT -> $VERSION   (Project.swift: $PLIST_KEY)
  commit       chore(release): $TAG
  tag          $TAG (annotated, on the release commit)
  assets       $DMG
               $SHA
  notes        $NOTES ($(wc -l < "$NOTES" | tr -d ' ') lines)
  remote       $REMOTE/$BRANCH
PLAN

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry run] nothing was changed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Proceed? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

echo "==> swift test"
swift test >/dev/null || die "tests failed — not releasing"

echo "==> bumping $PLIST_KEY to $VERSION"
sed -i '' "s/\"$PLIST_KEY\": \"$CURRENT\"/\"$PLIST_KEY\": \"$VERSION\"/" Project.swift
git diff --quiet -- Project.swift && die "version bump changed nothing — check Project.swift"

git add Project.swift
git commit -m "chore(release): $TAG"
RELEASE_COMMIT=$(git rev-parse HEAD)
git push "$REMOTE" "$BRANCH"

echo "==> packaging"
./scripts/package.sh
[ -f "$DMG" ] || die "expected $DMG, not produced"
[ -f "$SHA" ] || die "expected $SHA, not produced"

actual=$(shasum -a 256 "$DMG" | awk '{print $1}')
recorded=$(cat "$SHA")
[ "$actual" = "$recorded" ] || die "checksum mismatch: $DMG vs $SHA"

built_version=$(/usr/libexec/PlistBuddy -c "Print :$PLIST_KEY" \
  build/Build/Products/Release/TokenUsage.app/Contents/Info.plist)
[ "$built_version" = "$VERSION" ] \
  || die "packaged app reports $built_version, expected $VERSION"

echo "==> tagging $TAG"
git tag -a "$TAG" "$RELEASE_COMMIT" -m "$TAG"
git push "$REMOTE" "$TAG"

echo "==> creating GitHub release"
gh release create "$TAG" --title "$TAG" --notes-file "$NOTES" "$DMG" "$SHA"

echo
echo "Released $TAG"
echo "  commit  $RELEASE_COMMIT"
gh release view "$TAG" --json url,assets \
  -q '"  url     " + .url, "  assets  " + ([.assets[].name] | join(", "))'
