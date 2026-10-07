"""Puts the top-level elements of selected metadata files into Metadata API schema order.

The Metadata API deserialiser is order-sensitive for several types ("Element ... invalid at this location"). For the
types handled here the schema sequence is `fullName` (inherited from Metadata) followed by the type's own elements in
alphabetical order, so the order can be restored mechanically. Nested blocks are left as written.

Usage: python3 scripts/ci/normalize_metadata.py [--check] <dir> [<dir> ...]
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

NS = 'http://soap.sforce.com/2006/04/metadata'
SUFFIXES = ('.field-meta.xml', '.object-meta.xml', '.validationRule-meta.xml', '.flow-meta.xml')
ET.register_namespace('', NS)


def local(tag):
    return tag.split('}', 1)[-1]


def serialise(element, depth=0):
    pad = '    ' * depth
    name = local(element.tag)
    attrs = ''.join(f' {k}="{v}"' for k, v in element.attrib.items())
    if depth == 0:
        attrs = f' xmlns="{NS}"' + attrs
    children = list(element)
    if not children:
        text = (element.text or '').strip()
        if not text:
            return f'{pad}<{name}{attrs}/>\n'
        text = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        return f'{pad}<{name}{attrs}>{text}</{name}>\n'
    out = f'{pad}<{name}{attrs}>\n'
    for child in children:
        out += serialise(child, depth + 1)
    return out + f'{pad}</{name}>\n'


def normalise(path):
    tree = ET.parse(path)
    root = tree.getroot()
    children = list(root)
    ordered = sorted(children, key=lambda c: (local(c.tag) != 'fullName', local(c.tag)))
    if [id(c) for c in children] == [id(c) for c in ordered]:
        return False
    for child in children:
        root.remove(child)
    for child in ordered:
        root.append(child)
    with open(path, 'w') as handle:
        handle.write('<?xml version="1.0" encoding="UTF-8"?>\n' + serialise(root))
    return True


def main():
    check = '--check' in sys.argv
    dirs = [a for a in sys.argv[1:] if a != '--check']
    changed = []
    for directory in dirs:
        for path in glob.glob(os.path.join(directory, '**', '*.xml'), recursive=True):
            if path.endswith(SUFFIXES):
                if check:
                    root = ET.parse(path).getroot()
                    names = [local(c.tag) for c in root]
                    if names != sorted(names, key=lambda n: (n != 'fullName', n)):
                        changed.append(path)
                elif normalise(path):
                    changed.append(path)
    for path in changed:
        print(('OUT OF ORDER ' if check else 'normalised ') + path)
    if check and changed:
        sys.exit(1)
    print(f'{len(changed)} file(s) {"out of order" if check else "normalised"}')


if __name__ == '__main__':
    main()
