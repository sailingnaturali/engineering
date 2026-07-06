#!/usr/bin/env python3
"""publish.py — publish a staged post PR: rebase, bump, check, push, merge.

Each unpublished post is staged as an open PR whose branch adds exactly one
`_posts/` file (merge = publish). Those branches sit open for weeks while main
moves, so publishing by hand means remembering to rebase, re-date, and re-check
the build. This script is that checklist:

  1. find the `post/*` branch whose added post matches <slug>
  2. verify the branch adds exactly one `_posts/*.md` (staleness guard — any
     other diff vs main aborts, so a rotted branch can't drag old edits in)
  3. rebuild the branch from origin/main + that one file
  4. bump the date to today (script/bump.py) — or --date YYYY-MM-DD
  5. run script/lint-liquid.py and `bundle exec jekyll build`
  6. commit and push (--force-with-lease)
  7. merge the PR via `gh pr merge --squash` (skipped with --no-merge or when
     gh isn't available — it prints the manual step instead)

Merging deploys the site (pages.yml) and syndicates to dev.to (crosspost.yml).
Afterwards: move the post to Published in the planning repo's
engineering-blog-schedule.md.

Usage:
    publish.py <slug>                # slug substring, e.g. 'mqtt'
    publish.py <slug> --date 2026-07-07
    publish.py <slug> --no-merge     # push the rebuilt branch, merge by hand
    publish.py <slug> --skip-build   # skip the local jekyll build check
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import shutil
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    env = os.environ.get("ENGINEERING_REPO")
    if env:
        return Path(env).expanduser()
    return Path(__file__).resolve().parent.parent


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args],
                          check=check, capture_output=True, text=True)


def fail(msg: str) -> "NoReturn":  # noqa: F821
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def find_post_branch(repo: Path, slug: str) -> tuple[str, str]:
    """Return (branch, posts_file) for the post/* branch matching slug."""
    heads = git(repo, "ls-remote", "--heads", "origin", "post/*").stdout
    matches = []
    for line in heads.splitlines():
        branch = line.split("refs/heads/")[1]
        git(repo, "fetch", "origin", branch)
        diff = git(repo, "diff", "--name-only", "--diff-filter=A",
                   f"origin/main...origin/{branch}").stdout.split()
        posts = [f for f in diff if f.startswith("_posts/")]
        if any(slug.lower() in p.lower() for p in posts) or slug.lower() in branch.lower():
            matches.append((branch, posts))
    if not matches:
        fail(f"no post/* branch on origin matches {slug!r}")
    if len(matches) > 1:
        fail(f"{slug!r} is ambiguous: " + ", ".join(b for b, _ in matches))
    branch, posts = matches[0]
    if len(posts) != 1:
        fail(f"{branch} adds {len(posts)} _posts files (want exactly 1): {posts}")
    return branch, posts[0]


def main() -> None:
    ap = argparse.ArgumentParser(description="Publish a staged engineering-blog post PR.")
    ap.add_argument("slug", help="post/branch slug substring, e.g. 'mqtt'")
    ap.add_argument("--date", help="publish date YYYY-MM-DD (default: today)")
    ap.add_argument("--no-merge", action="store_true", help="push but don't merge the PR")
    ap.add_argument("--skip-build", action="store_true", help="skip the local jekyll build")
    args = ap.parse_args()
    date = args.date or dt.date.today().isoformat()
    repo = repo_root()

    if git(repo, "status", "--porcelain").stdout.strip():
        fail("working tree is dirty — commit or stash first")

    git(repo, "fetch", "origin", "main")
    branch, post_file = find_post_branch(repo, args.slug)
    extra = [f for f in git(repo, "diff", "--name-only",
                            f"origin/main...origin/{branch}").stdout.split()
             if f != post_file]
    if extra:
        fail(f"{branch} touches more than its post (stale branch?): {extra}\n"
             "rebase or clean it up first — one post file per branch.")

    print(f"branch: {branch}\npost:   {post_file}\ndate:   {date}")
    git(repo, "checkout", "-B", branch, "origin/main")
    git(repo, "checkout", f"origin/{branch}", "--", post_file)

    script_dir = Path(__file__).resolve().parent
    slug_for_bump = Path(post_file).stem
    subprocess.run([sys.executable, str(script_dir / "bump.py"),
                    slug_for_bump, "--date", date], check=True, cwd=repo)

    subprocess.run([sys.executable, str(script_dir / "lint-liquid.py")], check=True, cwd=repo)
    if args.skip_build:
        print("skipping jekyll build (--skip-build)")
    else:
        subprocess.run(["bundle", "exec", "jekyll", "build"], check=True, cwd=repo)

    git(repo, "commit", "-am", f"publish: set {slug_for_bump} to {date}")
    git(repo, "push", "--force-with-lease", "-u", "origin", branch)
    print(f"pushed {branch}")

    if args.no_merge:
        print(f"not merging (--no-merge). When ready: gh pr merge {branch} --squash")
        return
    if not shutil.which("gh"):
        print(f"gh not found — merge the PR for {branch} by hand (squash). "
              "Merge = publish; crosspost follows automatically.")
        return
    subprocess.run(["gh", "pr", "merge", branch, "--squash"], check=True, cwd=repo)
    print("merged — Pages will deploy, crosspost will follow. "
          "Now move the post to Published in the planning repo's engineering-blog-schedule.md.")


if __name__ == "__main__":
    main()
