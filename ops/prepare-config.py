"""Render text for a new EL7 host. Compatible with its system Python 2.7."""
from __future__ import print_function
import io
import re
import sys

BEGIN = "# BEGIN bigtop host preparation"
END = "# END bigtop host preparation"


def render(kind, original, values):
    outside = []
    inside = False
    seen = False
    for line in original.splitlines(True):
        if line.strip() == BEGIN:
            if inside or seen:
                raise ValueError("Duplicate managed block")
            inside, seen = True, True
        elif line.strip() == END:
            if not inside:
                raise ValueError("Unmatched end marker")
            inside = False
        elif not inside:
            outside.append(line)
    if inside:
        raise ValueError("Unclosed managed block")
    missing = list(values)
    kept = []
    for line in outside:
        words = line.partition("#")[0].split()
        if kind == "hosts" and len(words) >= 2:
            for record in values:
                ip, name = record.split()
                names = [n.lower().rstrip(".") for n in words[1:]]
                if name in names:
                    if ip != words[0] or names[0] != name:
                        raise ValueError("Existing hosts entry conflicts with " + name)
                    if record in missing:
                        missing.remove(record)
        elif kind == "chrony" and words:
            if words[0] in ("include", "confdir", "sourcedir", "refclock", "local"):
                raise ValueError("Site-managed chrony configuration needs operator review: " + words[0])
            if words[0] in ("server", "peer", "pool"):
                if len(words) < 2:
                    raise ValueError("Malformed chrony source")
                source = words[1]
                if source in values:
                    if source in missing:
                        missing.remove(source)
                elif re.match(r"^[0-3]\.centos\.pool\.ntp\.org$", source):
                    continue
                else:
                    raise ValueError("Existing chrony source conflicts with site settings: " + source)
        kept.append(line)
    text = u"".join(kept)
    if missing:
        if text and not text.endswith("\n"):
            text += "\n"
        entries = missing if kind == "hosts" else ["server " + s + " iburst" for s in missing]
        text += u"\n".join([BEGIN] + entries + [END, ""])
    return text


if __name__ == "__main__":
    mode, source, output = sys.argv[1:4]
    try:
        if mode not in ("hosts", "chrony"):
            raise ValueError("Invalid configuration file type")
        # Latin-1 is a transparent bytes-to-text mapping preserving site comments.
        with io.open(source, encoding="latin-1", newline="") as f:
            result = render(mode, f.read(), sys.argv[4:])
        with io.open(output, "w", encoding="latin-1", newline="") as f:
            f.write(result)
    except (IOError, ValueError) as error:
        sys.exit(str(error))
