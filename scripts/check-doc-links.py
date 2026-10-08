#!/usr/bin/env python3
"""Check that every relative markdown link in this repo resolves.

Links rot silently: a file gets renamed or a section pointer goes stale, and
nothing in the build notices, because the docs are not compiled. This is the
only automated guard on them.

For `#anchor` links it also checks the target file contains a heading with that
text -- because a renamed heading gives a link that resolves to a file but
lands the reader in the wrong place, which reads as "the docs are just vague".

Deliberately conservative on anchors: it compares heading text with all
punctuation, spacing and emoji removed, rather than reproducing GitHub's exact
slug algorithm. GitHub's rules are not fully specified (emoji handling in
particular varies), and a checker that "fixes" documents toward its own guess
about the slug is worse than no checker. So this reports a heading that was
renamed, and stays quiet about punctuation.

Usage: check-doc-links.py [root]      (default: the repository root)
Exit 0 if there are no problems, 1 otherwise.
"""

import os
import re
import sys

# The target may contain spaces (an anchor written as "#Some Heading"), so it
# cannot be matched as "anything but space". Grab up to the closing paren, then
# strip a trailing quoted title. An earlier version used [^)\s]+ here, which
# silently skipped every link whose anchor had a space in it -- the same silent
# skip that makes a broken checker look like a clean bill of health.
LINK = re.compile(r'\[[^\]]*\]\(([^)]+?)\s*\)')
TITLE = re.compile(r'\s+"[^"]*"\s*$')
ATX = re.compile(r'^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$')

def plain(text):
    """Heading or anchor reduced to comparable letters and digits.

    Drops punctuation, whitespace, the `` ` `` of inline code, link syntax and
    emphasis markers, so that "⚠️ 缺一个板级 U-Boot dtsi" and
    "缺一个板级-u-boot-dtsi" compare equal.
    """
    text = re.sub(r'`([^`]*)`', r'\1', text)         # inline code
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)  # links
    text = re.sub(r'[*_~]', '', text)                # emphasis / strikethrough
    return re.sub(r'[^\w]', '', text, flags=re.UNICODE).lower()

def headings(path):
    out = set()
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                m = ATX.match(line)
                if m:
                    out.add(plain(m.group(1)))
    except OSError:
        pass
    return out

def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
    files = sorted(os.path.join(dp, f)
                   for dp, dn, fs in os.walk(root)
                   if '.git' not in dp.split(os.sep)
                   for f in fs if f.endswith('.md'))

    problems = 0
    for src in files:
        base = os.path.dirname(src)
        fenced = False
        with open(src, encoding='utf-8', errors='replace') as fh:
            for n, line in enumerate(fh, 1):
                if line.lstrip().startswith('```'):
                    fenced = not fenced
                    continue
                if fenced or '](' not in line:
                    continue
                for target in LINK.findall(line):
                    target = TITLE.sub('', target)
                    if target.startswith(('http://', 'https://', 'mailto:')):
                        continue
                    rel, _, frag = target.partition('#')
                    dest = src if not rel else os.path.normpath(os.path.join(base, rel))
                    where = '%s:%d' % (os.path.relpath(src, root), n)
                    if not os.path.exists(dest):
                        print('%s: no such target: %s' % (where, target))
                        problems += 1
                    elif frag and dest.endswith('.md'):
                        if plain(frag) not in headings(dest):
                            print('%s: heading not found in %s: #%s'
                                  % (where, rel or os.path.basename(dest), frag))
                            problems += 1

    print('problems: %d' % problems)
    return 1 if problems else 0

if __name__ == '__main__':
    sys.exit(main())
