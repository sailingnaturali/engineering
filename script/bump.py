#!/usr/bin/env python3
"""bump.py — set an engineering-blog post's date to today (or a given date).

Each unpublished post is staged as an open PR in the `sailingnaturali/engineering`
repo as `_posts/<DATE>-<slug>.md`. Publishing = bump the date, then merge. This
script does the bump: it renames the file's date prefix AND rewrites the `date:`
frontmatter field, so Jekyll sorts/builds the post correctly.

Usage:
    bump.py <post>              # bump matching post to today's date
    bump.py <post> --date 2026-06-10
    bump.py <post> --commit     # also git-commit the rename on the current branch
    bump.py --list              # list posts in the engineering repo's _posts/
    bump.py <post> --dry-run    # show what would change, touch nothing

<post> matches a `_posts/*.md` file by slug substring (case-insensitive), ignoring
any existing date prefix. e.g. `bump.py launchd` matches
`_posts/2026-06-01-launchd-path-mcp-server-silent-fail.md`.

This script is vendored in the engineering repo at `script/bump.py`. The repo is
located automatically, in order:
  1. $ENGINEERING_REPO
  2. the repo this script lives in (its root, two dirs up from script/bump.py)
  3. ~/src/sailingnaturali/engineering, then ~/src/me/engineering
so it keeps working if the repo is moved or the script is run from elsewhere
(e.g. copied to /tmp by the publisher routine, which sets $ENGINEERING_REPO).
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
from pathlib import Path

DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}-")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def find_engineering_repo() -> Path:
    candidates: list[Path] = []
    env = os.environ.get("ENGINEERING_REPO")
    if env:
        candidates.append(Path(env).expanduser())
    # this script lives in the engineering repo at script/bump.py, so the repo
    # root is two parents up (skipped when run from /tmp — $ENGINEERING_REPO wins).
    here = Path(__file__).resolve()
    candidates.append(here.parent.parent)
    candidates.append(Path.home() / "src" / "sailingnaturali" / "engineering")
    candidates.append(Path.home() / "src" / "me" / "engineering")
    seen = set()
    for c in candidates:
        c = c.resolve()
        if c in seen:
            continue
        seen.add(c)
        if (c / "_posts").is_dir() and (c / ".git").exists():
            return c
    sys.exit(
        "could not locate the engineering repo (looked for a dir with _posts/ and .git/).\n"
        "Set ENGINEERING_REPO=/path/to/engineering and retry."
    )


def base_slug(filename: str) -> str:
    """Strip a leading YYYY-MM-DD- date prefix and the .md suffix."""
    name = filename[:-3] if filename.endswith(".md") else filename
    return DATE_PREFIX.sub("", name)


def find_post(posts_dir: Path, query: str) -> Path:
    q = base_slug(query).lower()
    matches = [p for p in sorted(posts_dir.glob("*.md")) if q in base_slug(p.name).lower()]
    if not matches:
        sys.exit(f"no post in {posts_dir} matches {query!r}. Try --list.")
    if len(matches) > 1:
        listing = "\n  ".join(p.name for p in matches)
        sys.exit(f"{query!r} matches multiple posts — be more specific:\n  {listing}")
    return matches[0]


def rewrite_date_field(text: str, new_date: str) -> str:
    """Replace the `date:` line inside the leading --- frontmatter block."""
    if not text.startswith("---"):
        sys.exit("post has no leading '---' frontmatter block; not touching it.")
    end = text.find("\n---", 3)
    if end == -1:
        sys.exit("could not find the closing '---' of the frontmatter block.")
    head, body = text[: end + 4], text[end + 4 :]
    if re.search(r"(?m)^date:", head):
        head = re.sub(r"(?m)^date:.*$", f"date: {new_date}", head, count=1)
    else:
        # insert right after the opening '---'
        head = head.replace("---", f"---\ndate: {new_date}", 1)
    return head + body


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def main() -> None:
    ap = argparse.ArgumentParser(description="Bump an engineering-blog post's date.")
    ap.add_argument("post", nargs="?", help="post slug substring (e.g. 'launchd')")
    ap.add_argument("--date", help="target date YYYY-MM-DD (default: today)")
    ap.add_argument("--commit", action="store_true", help="git-commit the rename on the current branch")
    ap.add_argument("--list", action="store_true", help="list posts and exit")
    ap.add_argument("--dry-run", action="store_true", help="show changes, touch nothing")
    args = ap.parse_args()

    repo = find_engineering_repo()
    posts = repo / "_posts"

    if args.list:
        for p in sorted(posts.glob("*.md")):
            print(p.name)
        return

    if not args.post:
        ap.error("the <post> argument is required (or use --list)")

    new_date = args.date or dt.date.today().isoformat()
    if not ISO_DATE.match(new_date):
        sys.exit(f"--date must be YYYY-MM-DD, got {new_date!r}")

    src = find_post(posts, args.post)
    slug = base_slug(src.name)
    dst = posts / f"{new_date}-{slug}.md"
    branch = git(repo, "branch", "--show-current") or "(detached)"

    print(f"repo:   {repo}")
    print(f"branch: {branch}")
    print(f"post:   {src.name}")
    print(f"rename: {src.name}  ->  {dst.name}")
    print(f"date:   -> {new_date}")
    if branch == "main":
        print("note:   you're on main — posts are normally bumped on their PR branch, then merged.")

    new_text = rewrite_date_field(src.read_text(), new_date)

    if args.dry_run:
        print("\n[dry-run] no files changed.")
        return

    src.write_text(new_text)  # rewrite date field in place first
    if src != dst:
        # git mv preserves history and stages the rename; fall back to plain rename
        try:
            git(repo, "mv", f"_posts/{src.name}", f"_posts/{dst.name}")
        except subprocess.CalledProcessError:
            src.rename(dst)
            try:
                git(repo, "add", f"_posts/{dst.name}")
            except subprocess.CalledProcessError:
                pass

    if args.commit:
        git(repo, "add", f"_posts/{dst.name}")
        git(repo, "commit", "-m", f"publish: set {slug} to {new_date}")
        print(f"\ncommitted on {branch}.")
        print("next: git push, then merge the PR -> GitHub Pages publishes it.")
    else:
        print("\ndone (staged). next:")
        print(f'  git -C {repo} commit -am "publish: set {slug} to {new_date}"')
        print("  git push   # updates the PR; then merge it -> GitHub Pages publishes")


if __name__ == "__main__":
    main()
