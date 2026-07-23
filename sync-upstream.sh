#!/bin/sh
# Keep this fork's branches in the intended layout:
#
#   upstream/main  →  origin/main   (mirror of mkj/dropbear)
#   origin/main    →  origin/master (integration branch; feature PRs target master)
#
# Usage:
#   ./sync-upstream.sh [integration-branch] [sync-branch]
#
# Defaults:
#   integration-branch = master
#   sync-branch        = chore/sync-upstream
#
# What it does:
#   1. Fetches upstream and fast-forwards (or force-updates) local+origin main
#      to match upstream/main.
#   2. Creates a worktree branch from master and merges origin/main into it.
#   3. Prints push / gh pr create --base master commands.
#
# Feature work: branch off master, open PRs into master (not main).
set -eu

UPSTREAM_URL="https://github.com/mkj/dropbear.git"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
MIRROR_BRANCH="main"
BASE_BRANCH="${1:-master}"
SYNC_BRANCH="${2:-chore/sync-upstream}"
WORKTREE_DIR="../dropbear-sync"

# Always operate from the repository root.
cd "$(git rev-parse --show-toplevel)"

# Ensure the upstream remote exists and always points at HTTPS mkj/dropbear.
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
	echo "Adding remote '$UPSTREAM_REMOTE' -> $UPSTREAM_URL"
	git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
else
	cur="$(git remote get-url "$UPSTREAM_REMOTE")"
	if [ "$cur" != "$UPSTREAM_URL" ]; then
		echo "Updating remote '$UPSTREAM_REMOTE' $cur -> $UPSTREAM_URL"
		git remote set-url "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
	fi
fi

echo "Fetching $UPSTREAM_REMOTE and origin ..."
git fetch "$UPSTREAM_REMOTE"
git remote set-head "$UPSTREAM_REMOTE" -a >/dev/null 2>&1 || true
git fetch origin

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
if ! git show-ref --verify --quiet "refs/remotes/$UPSTREAM_REF"; then
	echo "Missing refs/remotes/$UPSTREAM_REF after fetch" >&2
	exit 1
fi

# --- 1) Mirror upstream main onto origin/main ---------------------------------
echo "Updating local '$MIRROR_BRANCH' to match $UPSTREAM_REF ..."
git branch -f "$MIRROR_BRANCH" "$UPSTREAM_REF"

if git show-ref --verify --quiet "refs/remotes/origin/$MIRROR_BRANCH"; then
	if [ "$(git rev-parse "$MIRROR_BRANCH")" = "$(git rev-parse "origin/$MIRROR_BRANCH")" ]; then
		echo "origin/$MIRROR_BRANCH already matches $UPSTREAM_REF"
	else
		echo "Pushing $MIRROR_BRANCH -> origin/$MIRROR_BRANCH (force-with-lease) ..."
		git push --force-with-lease origin "refs/heads/$MIRROR_BRANCH:refs/heads/$MIRROR_BRANCH"
	fi
else
	echo "Creating origin/$MIRROR_BRANCH from $UPSTREAM_REF ..."
	git push -u origin "refs/heads/$MIRROR_BRANCH:refs/heads/$MIRROR_BRANCH"
fi

# Refresh local integration branch tip from origin.
if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
	git branch -f "$BASE_BRANCH" "origin/$BASE_BRANCH"
else
	echo "Missing origin/$BASE_BRANCH; create it first (e.g. from $MIRROR_BRANCH)." >&2
	exit 1
fi

# --- 2) Merge mirrored main into a PR branch for master -----------------------
if [ -e "$WORKTREE_DIR" ]; then
	echo "Removing stale worktree $WORKTREE_DIR ..."
	git worktree remove --force "$WORKTREE_DIR" || true
fi
git worktree prune
git branch -D "$SYNC_BRANCH" 2>/dev/null || true

echo "Creating worktree $WORKTREE_DIR on '$SYNC_BRANCH' (from '$BASE_BRANCH') ..."
git worktree add -b "$SYNC_BRANCH" "$WORKTREE_DIR" "$BASE_BRANCH"

cd "$WORKTREE_DIR"
echo "Merging origin/$MIRROR_BRANCH into $SYNC_BRANCH ..."
if git merge --no-edit "origin/$MIRROR_BRANCH"; then
	echo
	echo "Merge clean. Next steps:"
	echo "    cd $WORKTREE_DIR"
	echo "    git push -u origin $SYNC_BRANCH"
	echo "    gh pr create --base $BASE_BRANCH --head $SYNC_BRANCH --title \"chore: sync upstream main into $BASE_BRANCH\""
	echo
	echo "Feature PRs should also use --base $BASE_BRANCH."
	echo
	echo "After the sync PR is merged, clean up with:"
	echo "    git worktree remove $WORKTREE_DIR"
else
	echo
	echo "Merge has conflicts. Resolve them in: $WORKTREE_DIR"
	echo "    git -C $WORKTREE_DIR status"
	echo "    # edit, then:"
	echo "    git -C $WORKTREE_DIR add <files>"
	echo "    git -C $WORKTREE_DIR commit --no-edit"
	echo "    git -C $WORKTREE_DIR push -u origin $SYNC_BRANCH"
	echo "    gh pr create --base $BASE_BRANCH --head $SYNC_BRANCH"
	exit 1
fi
