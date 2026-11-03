"""Float distance, rather than ordering: a one-page layout shift is normal in either direction."""
import copy
from types import SimpleNamespace

import pytest

from paperole import check_items, checks


def paper(kind, page, cited, appendix=False):
    noun = {"figure": "Figure", "table": "Table", "code": "Algorithm"}[kind]
    block = {"kind": kind, "text": noun + " 3: Results.", "file": "main.tex", "start": 0, "end": 100,
             "parts": [[page, [72, 100, 300, 200]]]}
    links = [{"page": p, "rects": [[72, 500, 80, 510]], "text": "3", "targets": [0]} for p in cited]
    return SimpleNamespace(blocks=[block], links=links, targets=[{"block": 0}],
                           label_sites={"fig:result": [("main.tex", 50)]}, appendix_start=0 if appendix else 1,
                           parts=checks._Paper.parts, reading_key=lambda e: (e["page"], e["rects"][0][1]))


def findings(p, n=1):
    found = checks.float_before(p) + checks.float_far(p)
    checks._keys(found, n)
    return found


@pytest.mark.parametrize("kind", ["figure", "table", "code"])
@pytest.mark.parametrize("offset,code", [(-3, "float_before"), (-2, "float_before"), (-1, None), (0, None),
                                        (1, None), (2, "float_far"), (3, "float_far")])
def test_only_two_or_more_pages_in_either_direction(kind, offset, code):
    # Page 4 vs page 5 is the reported false positive; page 4 vs page 6 is the inclusive boundary.
    found = findings(paper(kind, 3, [3 - offset]))
    if code is None:
        assert found == []
        return
    c, = found
    noun = {"figure": "Figure", "table": "Table", "code": "Algorithm"}[kind]
    direction = "before" if offset < 0 else "after"
    assert c["code"] == code and c["key"] == code + "|fig:result"
    assert c["text"] == "{} 3 · {} pages {} its first citation".format(noun, abs(offset), direction)
    assert [p["page"] for p in c["places"]] == [3, 3 - offset]
    assert "{} pages {}".format(abs(offset), direction) in c["detail"]
    assert "after the paragraph" not in c["note"]


@pytest.mark.parametrize("kind", ["figure", "table", "code"])
def test_existing_exemptions_and_missing_citations(kind):
    assert findings(paper(kind, 0, [3])) == []  # existing first-page teaser exemption
    assert findings(paper(kind, 3, [0], appendix=True)) == []
    assert findings(paper(kind, 3, [6], appendix=True)) == []
    assert findings(paper(kind, 3, [])) == []


def test_still_uses_first_citation_not_a_later_repeat():
    c, = findings(paper("figure", 3, [3, 0, 2]))
    assert c["code"] == "float_far"
    assert [p["page"] for p in c["places"]] == [3, 0]


@pytest.mark.parametrize("distance,expected", [(1, "fixed"), (2, "still")])
def test_old_sent_check_is_rechecked_without_renumbering(distance, expected):
    old = {"state": "new", "text": "Figure 3 · before its first citation", "detail": "Old rule.",
           "note": "Old rule.", "places": []}
    lg = {"rounds": [{"n": 1, "last_check_seq": 1}, {"n": 2}], "check_items": {
        "A1-01": {"id": "A1-01", "key": "float_before|fig:result", "code": "float_before",
                  "group": "references", "created_round": 1, "rounds": {"1": copy.deepcopy(old)}}}}
    check_items.sync(lg, 2, findings(paper("figure", 3, [3 + distance]), 2), checks.GROUPS)
    assert list(lg["check_items"]) == ["A1-01"]
    assert lg["check_items"]["A1-01"]["rounds"]["2"]["state"] == expected
    assert lg["check_items"]["A1-01"]["rounds"]["1"] == old  # finished history is unchanged


def test_old_unsent_one_page_warning_disappears_in_the_open_round():
    lg = {"rounds": [{"n": 1, "last_check_seq": 1}], "check_items": {
        "A1-01": {"id": "A1-01", "key": "float_before|fig:result", "code": "float_before",
                  "group": "references", "created_round": 1, "rounds": {"1": {"state": "new"}}}}}
    check_items.sync(lg, 1, findings(paper("table", 3, [4])), checks.GROUPS)
    assert lg["check_items"] == {}
