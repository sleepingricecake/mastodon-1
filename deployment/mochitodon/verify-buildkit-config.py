#!/usr/bin/env python3
"""Compare the small reviewed BuildKit configuration after Buildx formats it."""
import pathlib
import re
import sys


def validate(data):
    if not isinstance(data, bytes) or len(data) > 16384:
        raise ValueError('BuildKit configuration size rejected')
    text = data.decode('ascii')
    section = None
    sections = set()
    found = False
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        if line in ('[worker]', '[worker.oci]'):
            if line in sections:
                raise ValueError('Duplicate BuildKit section rejected')
            sections.add(line)
            section = line
            continue
        if section == '[worker.oci]' and re.fullmatch(r'max-parallelism\s*=\s*1', line) and not found:
            found = True
            continue
        raise ValueError('Unreviewed BuildKit setting rejected')
    if not found:
        raise ValueError('BuildKit parallelism limit missing')


def main():
    if len(sys.argv) != 3:
        raise SystemExit('Expected reviewed and actual configuration paths')
    for filename in sys.argv[1:]:
        validate(pathlib.Path(filename).read_bytes())
    print('Reviewed BuildKit settings match; formatting may differ')


if __name__ == '__main__':
    main()
