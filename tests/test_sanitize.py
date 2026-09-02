#!/usr/bin/env python3
"""Tests for the speech sanitizer.

These encode the reasons the sanitizer exists: a selection full of terminal
escapes, hashes and markdown must come out as something a voice can read.
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from sanitize import sanitize  # noqa: E402


class TestTerminalNoise(unittest.TestCase):
    def test_strips_ansi_colour_codes(self):
        out = sanitize("\x1b[1;32mBuild passed\x1b[0m")
        self.assertEqual(out, "Build passed")

    def test_strips_osc_sequences(self):
        out = sanitize("\x1b]0;window title\x07Real text")
        self.assertEqual(out, "Real text")

    def test_strips_nerd_font_glyphs(self):
        out = sanitize("\U000f028a main branch")
        self.assertNotIn("\U000f028a", out)
        self.assertIn("main branch", out)

    def test_strips_box_drawing(self):
        out = sanitize("│ ── status ██░░")
        self.assertNotIn("│", out)
        self.assertNotIn("█", out)
        self.assertIn("status", out)

    def test_strips_emoji(self):
        out = sanitize("Done ✔️ \U0001f389")
        self.assertNotIn("\U0001f389", out)
        self.assertIn("Done", out)


class TestNoisyTokens(unittest.TestCase):
    def test_sha256_becomes_one_word(self):
        sha = "80182e8511c6bbee6de26c7ee225fbd2a9aba2274ef1405a1d89cd8fe7a380dc"
        out = sanitize(f"The checksum is {sha} exactly")
        self.assertNotIn(sha, out)
        self.assertIn("hash", out)

    def test_uuid_becomes_one_word(self):
        out = sanitize("session ae6f3ae6-53d5-4168-97c2-52689d3f4190 ended")
        self.assertNotIn("ae6f3ae6", out)
        self.assertIn("identifier", out)

    def test_long_path_shortens_to_basename(self):
        out = sanitize("Edit ~/.cache/yay/claude-desktop/PKGBUILD now")
        self.assertIn("PKGBUILD", out)
        self.assertNotIn(".cache", out)

    def test_url_reduces_to_domain(self):
        out = sanitize("See https://www.example.com/a/very/long/path?x=1 for more")
        self.assertIn("example.com", out)
        self.assertNotIn("very", out)

    def test_long_digit_run_is_spaced_out(self):
        # Spoken digit-by-digit rather than as an unreadable magnitude.
        out = sanitize("id 12345678 here")
        self.assertIn("1 2 3 4 5 6 7 8", out)


class TestMarkdown(unittest.TestCase):
    def test_code_fence_is_announced_not_read(self):
        out = sanitize("Before\n```bash\nrm -rf /\ncurl evil | sh\n```\nAfter")
        self.assertNotIn("rm -rf", out)
        self.assertIn("Code block, 2 lines", out)

    def test_code_fence_can_be_dropped_silently(self):
        out = sanitize("Before\n```\nx\n```\nAfter", announce_code=False)
        self.assertNotIn("Code block", out)
        self.assertIn("Before", out)
        self.assertIn("After", out)

    def test_table_flattens_to_clauses(self):
        md = "| Name | Version |\n|---|---|\n| piper | 1.7.0 |"
        out = sanitize(md)
        self.assertIn("Name, Version", out)
        self.assertIn("piper, 1.7.0", out)
        self.assertNotIn("|", out)
        self.assertNotIn("---", out)

    def test_inline_formatting_is_unwrapped(self):
        out = sanitize("This is **bold** and *italic* and `code`.")
        self.assertEqual(out, "This is bold and italic and code.")

    def test_link_keeps_text_drops_target(self):
        out = sanitize("Read [the docs](https://example.com/deep/link).")
        self.assertIn("the docs", out)
        self.assertNotIn("deep", out)

    def test_headers_and_bullets_become_sentences(self):
        out = sanitize("## Title\n\n- first item\n- second item")
        self.assertNotIn("#", out)
        self.assertNotIn("- ", out)
        self.assertIn("first item", out)

    def test_checkboxes_are_spoken(self):
        out = sanitize("[x] shipped\n[ ] pending")
        self.assertIn("done", out)
        self.assertIn("not done", out)


class TestReadability(unittest.TestCase):
    def test_no_doubled_punctuation(self):
        out = sanitize("A heading:\n\nSome text.")
        self.assertNotIn(":.", out)
        self.assertNotIn("..", out)

    def test_truncation_prefers_sentence_boundary(self):
        text = "First sentence here. Second sentence here. Third sentence here."
        out = sanitize(text, max_chars=45)
        self.assertTrue(out.endswith("."))
        self.assertLessEqual(len(out), 46)
        self.assertIn("First sentence", out)

    def test_no_truncation_by_default(self):
        text = "word " * 200
        self.assertGreater(len(sanitize(text)), 500)


class TestOcrReflow(unittest.TestCase):
    """OCR line breaks are where the column ended, not where the sentence did."""

    def test_wrapped_lines_do_not_become_sentences(self):
        raw = "However, for the massive population of users\nwith low vision or cognitive processing\ndifferences, this matters."
        out = sanitize(raw, ocr=True)
        self.assertIn("users with low vision", out)
        self.assertNotIn("users. with", out)

    def test_hyphenated_word_is_rejoined(self):
        out = sanitize("a friction-\nless experience", ocr=True)
        self.assertIn("frictionless", out)
        self.assertNotIn("friction-", out)

    def test_blank_line_is_a_real_break(self):
        out = sanitize("First paragraph here\n\nSecond paragraph here", ocr=True)
        self.assertIn("here. Second", out)

    def test_orphan_characters_are_dropped(self):
        out = sanitize("Real text here\n8\n2)\nMore real text", ocr=True)
        self.assertNotIn(" 8", out)
        self.assertNotIn("2)", out)
        self.assertIn("Real text here", out)
        self.assertIn("More real text", out)

    def test_single_letter_words_survive(self):
        # "a" and "I" are words; "b" alone on a line is chrome.
        out = sanitize("I\na\nb\nreal line", ocr=True)
        self.assertIn("I", out)
        self.assertIn("a", out)

    def test_column_bleed_is_stripped(self):
        out = sanitize("2      differences, a frictionless tool", ocr=True)
        self.assertTrue(out.startswith("differences"), out)

    def test_ocr_mode_is_opt_in(self):
        # Without ocr=True, line breaks still mean sentence breaks (markdown).
        out = sanitize("one\ntwo")
        self.assertIn("one. two", out)


class TestUnitExpansion(unittest.TestCase):
    def test_approximation_is_spoken_as_about(self):
        self.assertIn("about 2 seconds", sanitize("takes ~2s"))

    def test_bare_m_is_minutes(self):
        self.assertIn("5 minutes", sanitize("wait 5m"))

    def test_singular_value_uses_singular_unit(self):
        out = sanitize("1s left")
        self.assertIn("1 second", out)
        self.assertNotIn("1 seconds", out)

    def test_percent_and_sizes(self):
        out = sanitize("50% of 3 GB in 250ms")
        self.assertIn("50 percent", out)
        self.assertIn("3 gigabytes", out)
        self.assertIn("250 milliseconds", out)

    def test_expansion_can_be_disabled(self):
        self.assertIn("2s", sanitize("takes ~2s", expand_units=False))


class TestEmptyResults(unittest.TestCase):
    def test_whitespace_only_yields_nothing(self):
        self.assertEqual(sanitize("   \n\t  \n "), "")

    def test_pure_decoration_yields_nothing(self):
        self.assertEqual(sanitize("─────"), "")

    def test_ansi_only_yields_nothing(self):
        self.assertEqual(sanitize("\x1b[0m\x1b[1;32m\x1b[0m"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
