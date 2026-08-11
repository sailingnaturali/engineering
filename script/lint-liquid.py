#!/usr/bin/env python3
"""lint-liquid.py — fail if a post has Liquid-significant syntax outside {% raw %}.

GitHub Pages runs Liquid over every post body before Markdown rendering. An
unguarded `{{ … }}` is silently rendered to an empty string (blanking template
code out of published code blocks), and some constructs (`default({})`) are hard
Liquid syntax errors that fail the whole build. House rule: any post whose body
contains `{{` or `{%` wraps the body in `{% raw %}` … `{% endraw %}`.

This lint enforces the rule: it strips frontmatter, {% raw %} spans, and the
allowed internal-link tags ({% post_url … %}, {% link … %}) from each
`_posts/*.md`, then flags any `{{` or `{%` that remains. A post that ever needs
other intentional Liquid can be added to ALLOW below — none do today.

It also checks every root-relative asset a post references (`/assets/img/…`,
the post's figures) actually exists in the repo. Jekyll builds a missing image
without complaint, so the break only shows up as a broken figure on the live
site — and by then merge = publish has already happened.

Usage: script/lint-liquid.py [posts_dir]   (default: _posts/ next to this script)
Exit 0 = clean, 1 = violations (listed as file:line).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Posts allowed to contain live Liquid outside {% raw %} (filenames, no dir).
ALLOW: set[str] = set()

FRONTMATTER = re.compile(r"\A---\n.*?\n---\n", re.DOTALL)
RAW_SPAN = re.compile(r"{%\s*raw\s*%}.*?{%\s*endraw\s*%}", re.DOTALL)
# Internal-link tags posts are encouraged to use (build fails loudly on typos,
# unlike a hardcoded URL) — legitimate outside {% raw %}.
ALLOWED_TAG = re.compile(r"{%\s*(?:post_url|link)\s[^%]*%}")
LIQUID = re.compile(r"{{|{%")
# Root-relative asset reference: ](/assets/…) in markdown, src="/assets/…" in HTML.
ASSET_REF = re.compile(r"""!?\[[^\]]*\]\((/assets/[^)\s]+)\)|(?:src|href)=["'](/assets/[^"']+)["']""")


def violations(text: str) -> list[int]:
    """Return 1-based line numbers with Liquid syntax outside raw guards."""
    body = FRONTMATTER.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    body = RAW_SPAN.sub(lambda m: "\n" * m.group(0).count("\n"), body)
    body = ALLOWED_TAG.sub("", body)
    return [i for i, line in enumerate(body.splitlines(), 1) if LIQUID.search(line)]


def asset_problems(text: str, root: Path) -> list[tuple[int, str]]:
    """Return (1-based line, message) for each broken /assets/… reference.

    Fence-aware, like Devto::Transform.absolutize — a code block demonstrating
    an asset path (`src="/assets/entry-client-xxxx.js"`) is illustration, not a
    reference to a file we ship.
    """
    out, in_fence = [], False
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # A "](/assets/" the reference regex couldn't match means the alt text
        # contains a "]", which breaks both kramdown and the dev.to absolutizer
        # (Devto::Transform's MD_LINK is \[[^\]]*\] too) — the figure then
        # syndicates as a relative path. Silent otherwise, so flag it here.
        if line.count("](/assets/") > len(ASSET_REF.findall(line)):
            out.append((i, "malformed image link — is there a ']' in the alt text?"))
        for md_path, html_path in ASSET_REF.findall(line):
            ref = md_path or html_path
            if not (root / ref.lstrip("/").split("#")[0]).exists():
                out.append((i, f"asset not in the repo: {ref}"))
    return out


def main() -> int:
    posts_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "_posts"
    root = posts_dir.parent
    bad = 0
    for post in sorted(posts_dir.glob("*.md")):
        text = post.read_text()
        for line_no, msg in asset_problems(text, root):
            print(f"{post}:{line_no}: {msg}")
            bad += 1
        if post.name in ALLOW:  # ALLOW exempts Liquid only, never a broken asset
            continue
        for line_no in violations(text):
            print(f"{post}:{line_no}: Liquid syntax outside {{% raw %}} — "
                  f"wrap the post body in {{% raw %}} … {{% endraw %}}")
            bad += 1
    if bad:
        print(f"\n{bad} problem(s). Unguarded Liquid gets blanked or rejected by "
              f"Jekyll; a missing asset publishes as a broken image.", file=sys.stderr)
        return 1
    print(f"post lint: {len(list(posts_dir.glob('*.md')))} posts clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
