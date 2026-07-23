#!/bin/sh
# Sync the upstream mkj/dropbear main branch into a sync branch using a
# git worktree, so your current working tree / checked-out branch is untouched.
#
# Usage:
#   ./sync-upstream.sh [base-branch] [sync-branch]
#
# Defaults:
#   base-branch = master   (this fork's integration branch)
#   sync-branch = chore/sync-upstream
#
# After it finishes cleanly, push the sync branch and open a PR into the base
# branch. If there are conflicts, the script stops and tells you where to fix
# them.
set -eu

UPSTREAM_URL="https://github.com/mkj/dropbear.git"
UPSTREAM_REMOTE="upstream"
# mkj/dropbear default branch is main; this fork integrates on master.
UPSTREAM_BRANCH="main"
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

# Refresh the local base branch from origin if it exists there.
if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
	git branch -f "$BASE_BRANCH" "origin/$BASE_BRANCH"
fi

# Remove any stale worktree / branch from a previous run.
if [ -e "$WORKTREE_DIR" ]; then
	echo "Removing stale worktree $WORKTREE_DIR ..."
	git worktree remove --force "$WORKTREE_DIR" || true
fi
git worktree prune
git branch -D "$SYNC_BRANCH" 2>/dev/null || true

echo "Creating worktree $WORKTREE_DIR on new branch '$SYNC_BRANCH' (from '$BASE_BRANCH') ..."
git worktree add -b "$SYNC_BRANCH" "$WORKTREE_DIR" "$BASE_BRANCH"

cd "$WORKTREE_DIR"
echo "Merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH ..."
if git merge --no-edit "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
	echo
	echo "Merge clean. Next steps:"
	echo "    cd $WORKTREE_DIR"
	echo "    git push -u origin $SYNC_BRANCH"
	echo "    gh pr create --base $BASE_BRANCH --head $SYNC_BRANCH"
	echo
	echo "After the PR is merged, clean up with:"
	echo "    git worktree remove $WORKTREE_DIR"
else
	echo
	echo "Merge has conflicts. Resolve them in: $WORKTREE_DIR"
	echo "    git -C $WORKTREE_DIR status        # list conflicted files"
	echo "    # edit the files, then:"
	echo "    git -C $WORKTREE_DIR add <files>"
	echo "    git -C $WORKTREE_DIR commit --no-edit"
	echo "    git -C $WORKTREE_DIR push -u origin $SYNC_BRANCH"
	exit 1
fi
