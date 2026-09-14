#!/usr/bin/env python3
r"""Find bare $var (not ${...} and not escaped \$) inside Groovy sh blocks.

Inside a Groovy sh block, Groovy interpolates $name. Shell variables MUST be
written \$name; ${...} is Groovy interpolation (intended, for Groovy values).
A bare $f therefore becomes a MissingPropertyException at RUNTIME - the build
crashes only when that line is reached, so it survives review.

This scanner catches that class of bug across the whole Jenkinsfile instead of
patching instances one at a time.
"""
import re
import sys

AQ = '"' * 3
SQ = "'" * 3


def scan(path):
    lines = open(path).read().split('\n')
    in_sh = False
    delim = None
    findings = []

    open_re = re.compile(r'\bsh\s*(?:\(\s*)?(?:script:\s*)?(' + AQ + '|' + SQ + ')')

    for i, line in enumerate(lines, 1):
        if not in_sh:
            m = open_re.search(line)
            if not m:
                continue
            in_sh = True
            delim = m.group(1)
            rest = line[m.end():]
            if delim in rest:
                in_sh = False
                continue
            check = rest
        else:
            if delim in line:
                check = line[:line.index(delim)]
                in_sh = False
            else:
                check = line

        # Single-quoted sh blocks ('''...''') are NOT interpolated by Groovy,
        # so a bare $var there is correct shell and must not be flagged.
        if delim == SQ:
            continue

        for m in re.finditer(r'(?<!\\)\$(?!\{)([A-Za-z_][A-Za-z0-9_]*)', check):
            findings.append((i, m.group(0), line.strip()[:110]))
    return findings


def main():
    findings = scan('Jenkinsfile')
    if findings:
        print('BARE SHELL VARS INSIDE GROOVY sh BLOCKS (must be \\$):')
        for ln, var, txt in findings:
            print('  line %d: %s\n      %s' % (ln, var, txt))
        print('\n%d finding(s)' % len(findings))
        return 1
    print('OK - no unescaped shell variables in Groovy sh blocks')
    return 0


if __name__ == '__main__':
    sys.exit(main())
