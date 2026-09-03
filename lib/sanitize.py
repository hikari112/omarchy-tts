#!/usr/bin/env python3
"""Turn terminal / markdown text into something worth hearing out loud.

Reads text on stdin, writes speakable text on stdout. Exits 1 if nothing
speakable survives, so callers can stay silent instead of playing dead air.
"""
import argparse
import json
import re
import sys
import unicodedata

# --- character-class scrubbing -------------------------------------------

ANSI_CSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
ANSI_OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
ANSI_REST = re.compile(r"\x1b[@-_]")

# Nerd Font glyphs live in the Private Use Areas; Omarchy uses them heavily.
PUA = re.compile("[\ue000-\uf8ff\U000f0000-\U000ffffd\U00100000-\U0010fffd]")
BOX = re.compile("[\u2500-\u259f\u25a0-\u25ff\u2b00-\u2bff]")
EMOJI = re.compile(
    "[\U0001f000-\U0001faff\u2600-\u27bf\u2190-\u21ff\ufe00-\ufe0f\u200d]"
)

# --- structural markdown --------------------------------------------------

FENCE = re.compile(r"^\s*(?:```|~~~)")
TABLE_SEP = re.compile(r"^\s*\|?[\s:|-]*\|[\s:|-]*$")
HRULE = re.compile(r"^\s*(?:[-*_=]\s*){3,}$")

MD_LINK = re.compile(r"\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
MD_IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
MD_HEADER = re.compile(r"^\s{0,3}#{1,6}\s*")
MD_QUOTE = re.compile(r"^\s{0,3}>\s?")
MD_BULLET = re.compile(r"^(\s*)[-*+]\s+")
MD_CHECK = re.compile(r"^(\s*)\[([ xX])\]\s+")
MD_BOLD = re.compile(r"(\*\*|__)(.+?)\1", re.S)
MD_ITALIC = re.compile(r"(?<![\w*])(\*|_)(?!\s)(.+?)(?<!\s)\1(?![\w*])", re.S)
MD_STRIKE = re.compile(r"~~(.+?)~~", re.S)
INLINE_CODE = re.compile(r"`([^`\n]+)`")
HTML_TAG = re.compile(r"</?[a-zA-Z][^>]{0,200}>")

# --- OCR reflow -----------------------------------------------------------

# A line holding one stray character (UI chrome bleeding into the grab) or a
# short run of punctuation. "a", "A", "I" are real words and must survive.
ORPHAN_LINE = re.compile(
    r"^(?:[^\w\s]{1,3}"                      # ")" or "--"
    r"|[b-hj-zB-HJ-Z0-9][^\w\s]?"            # "8", "2)"
    r"|[^\w\s]?[b-hj-zB-HJ-Z0-9])$"          # "(a"
)

# A stray character from a neighbouring column, separated from the real text
# by a wide gutter: "2      differences, a frictionless..."
COLUMN_BLEED = re.compile(r"^\s*[\w\)\]]{1,2}\s{4,}(?=\S)")

# --- noisy tokens ---------------------------------------------------------

URL = re.compile(r"\b(?:https?://|www\.)([^\s/)>\]]+)(\S*)", re.I)
HEXBLOB = re.compile(r"\b(?:0x)?[0-9a-fA-F]{12,}\b")
B64BLOB = re.compile(
    r"(?<![A-Za-z0-9+/])"
    r"(?=[A-Za-z0-9+/]{28,}={0,2}(?![A-Za-z0-9+/=]))"
    r"(?=[A-Za-z0-9+/]*[0-9+/])"
    r"[A-Za-z0-9+/]{28,}={0,2}"
)
PATH = re.compile(r"(?<![\w.])(?:~|\.{1,2})?(?:/[\w.@+-]+){2,}/?")
UUID = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I
)
LONGNUM = re.compile(r"\b\d{7,}\b")
# A leading "~" is read as "about"; without it the tilde is simply dropped and
# an approximation is spoken as though it were exact.
UNIT = re.compile(
    r"(~\s*)?\b(\d+(?:\.\d+)?)\s*"
    r"(ms|secs|sec|s|mins|min|m|hrs|hr|h|kb|mb|gb|tb|%)(?![\w.])",
    re.I,
)
REPEAT_PUNCT = re.compile(r"([!?.,;:])\1{1,}")
MULTISPACE = re.compile(r"[ \t ]+")
BLANKLINES = re.compile(r"\n{2,}")


def _reflow_ocr(text: str) -> str:
    """Rejoin OCR's wrapped lines into paragraphs.

    OCR line breaks are where the *column* ended, not where the sentence did.
    Treating them as sentence boundaries makes the voice stop. every. few.
    words. Only a blank line is a real break.
    """
    paras, cur = [], []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            if cur:
                paras.append(cur)
                cur = []
            continue
        line = COLUMN_BLEED.sub("", line)
        if not line or ORPHAN_LINE.match(line):
            continue
        cur.append(line)
    if cur:
        paras.append(cur)

    joined = []
    for para in paras:
        buf = ""
        for line in para:
            if not buf:
                buf = line
            elif buf.endswith("-"):
                buf = buf[:-1] + line          # word split across lines
            else:
                buf += " " + line
        joined.append(buf)
    return "\n\n".join(joined)


def _strip_control(text: str) -> str:
    text = ANSI_OSC.sub("", text)
    text = ANSI_CSI.sub("", text)
    text = ANSI_REST.sub("", text)
    out = []
    for ch in text:
        if ch in "\n\t":
            out.append(ch)
            continue
        if unicodedata.category(ch) in ("Cc", "Cf"):
            continue
        out.append(ch)
    return "".join(out)


def _shorten_path(match: re.Match) -> str:
    raw = match.group(0).rstrip("/")
    base = raw.rsplit("/", 1)[-1]
    return base if base else "root"


def _shorten_url(match: re.Match) -> str:
    host = match.group(1).lower()
    if host.startswith("www."):
        host = host[4:]
    return host


def _handle_fences(lines, announce_code):
    """Drop fenced code blocks, optionally announcing their size."""
    out, in_fence, count = [], False, 0
    for line in lines:
        if FENCE.match(line):
            if in_fence:
                if announce_code and count:
                    noun = "line" if count == 1 else "lines"
                    out.append(f"Code block, {count} {noun}.")
                in_fence, count = False, 0
            else:
                in_fence, count = True, 0
            continue
        if in_fence:
            count += 1
            continue
        out.append(line)
    if in_fence and announce_code and count:
        noun = "line" if count == 1 else "lines"
        out.append(f"Code block, {count} {noun}.")
    return out


def _handle_table_row(line: str) -> str:
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    cells = [c for c in cells if c]
    return ", ".join(cells) + "." if cells else ""


UNIT_NAMES = {
    "ms": "milliseconds", "s": "seconds", "sec": "seconds", "secs": "seconds",
    "m": "minutes", "min": "minutes", "mins": "minutes",
    "h": "hours", "hr": "hours", "hrs": "hours",
    "kb": "kilobytes", "mb": "megabytes", "gb": "gigabytes", "tb": "terabytes",
    "%": "percent",
}


def _expand_unit(match: re.Match) -> str:
    approx, value, unit = match.group(1), match.group(2), match.group(3).lower()
    name = UNIT_NAMES[unit]
    if value == "1" and name.endswith("s") and unit != "%":
        name = name[:-1]
    return f"{'about ' if approx else ''}{value} {name}"


def sanitize(text: str, announce_code=True, max_chars=0, ocr=False,
             urls="domain", inline_code=True, strip_markdown=True,
             expand_units=True) -> str:
    text = _strip_control(text)
    if ocr:
        text = _reflow_ocr(text)
    text = PUA.sub(" ", text)
    text = BOX.sub(" ", text)
    text = EMOJI.sub(" ", text)

    lines = _handle_fences(text.splitlines(), announce_code)

    cleaned = []
    for line in lines:
        if HRULE.match(line) or TABLE_SEP.match(line):
            continue
        if strip_markdown:
            line = MD_HEADER.sub("", line)
            line = MD_QUOTE.sub("", line)
            line = MD_CHECK.sub(
                lambda m: f"{m.group(1)}{'done, ' if m.group(2).lower() == 'x' else 'not done, '}",
                line,
            )
            line = MD_BULLET.sub(r"\1", line)
            if line.strip().startswith("|"):
                line = _handle_table_row(line)
        cleaned.append(line)

    text = "\n".join(cleaned)

    text = MD_IMAGE.sub(r"\1", text)
    text = MD_LINK.sub(r"\1", text)
    text = HTML_TAG.sub(" ", text)
    if strip_markdown:
        text = MD_BOLD.sub(r"\2", text)
        text = MD_STRIKE.sub(r"\1", text)
        text = MD_ITALIC.sub(r"\2", text)
    text = INLINE_CODE.sub(r"\1" if inline_code else " inline code ", text)

    text = UUID.sub(" identifier ", text)
    text = URL.sub((lambda _m: "link") if urls == "link" else _shorten_url, text)
    text = PATH.sub(_shorten_path, text)
    text = HEXBLOB.sub(" hash ", text)
    text = B64BLOB.sub(" encoded blob ", text)
    text = LONGNUM.sub(lambda m: " ".join(m.group(0)), text)
    if expand_units:
        text = UNIT.sub(_expand_unit, text)

    # Line breaks become sentence boundaries so the voice actually pauses.
    text = BLANKLINES.sub(". ", text)
    text = text.replace("\n", ". ")
    text = REPEAT_PUNCT.sub(r"\1", text)
    text = re.sub(r"\s+([.,;:!?])", r"\1", text)
    text = re.sub(r"(?:\.\s*){2,}", ". ", text)
    text = re.sub(r"[,;:]+\s*([.!?])", r"\1", text)
    text = MULTISPACE.sub(" ", text).strip()
    text = re.sub(r"^[.,;:\s]+", "", text)

    if max_chars and len(text) > max_chars:
        cut = text[:max_chars]
        pivot = max(cut.rfind("."), cut.rfind("!"), cut.rfind("?"))
        if pivot > max_chars * 0.4:
            text = cut[: pivot + 1]
        else:
            boundary = cut.rsplit(" ", 1)[0] if " " in cut else cut
            boundary = boundary.rstrip(" ,;:") or cut
            if boundary.endswith((".", "!", "?")):
                text = boundary
            elif len(boundary) < max_chars:
                text = boundary + "."
            else:
                # An unbroken token has no safe word boundary. Replace its
                # final character rather than exceeding the caller's limit.
                text = boundary[:-1] + "."

    return text.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description="Make text speakable.")
    ap.add_argument("--max-chars", type=int, default=0,
                    help="truncate at a sentence boundary near N chars (0 = no limit)")
    ap.add_argument("--ocr", action="store_true",
                    help="input came from OCR: rejoin wrapped lines, drop stray characters")
    ap.add_argument("--no-announce-code", action="store_true",
                    help="drop code blocks silently instead of naming them")
    ap.add_argument("--config", help="read sanitizer options from this JSON config")
    args = ap.parse_args()

    opts = {}
    if args.config:
        try:
            with open(args.config, encoding="utf-8") as handle:
                opts = json.load(handle).get("sanitizer", {})
        except (OSError, ValueError, TypeError):
            opts = {}
    out = sanitize(
        sys.stdin.read(),
        announce_code=(not args.no_announce_code and opts.get("announceCodeBlocks", True)),
        max_chars=args.max_chars,
        ocr=args.ocr,
        urls=opts.get("urls", "domain"),
        inline_code=opts.get("inlineCode", True),
        strip_markdown=opts.get("stripMarkdown", True),
        expand_units=opts.get("expandUnits", True),
    )
    if not out or not any(char.isalnum() for char in out):
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
