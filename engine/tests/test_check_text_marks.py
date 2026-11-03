"""Bibliography checks select text lines, including hanging first words, without neighbouring entries."""
import pymupdf
import pytest

from paperole import checks


@pytest.fixture
def paper(tmp_path):
    doc = pymupdf.open()
    p = doc.new_page(width=600, height=420)
    for x, who in [(72, "Di Doe"), (330, "Bo Roe")]:
        p.insert_text((x, 50), "Previous reference stays clear.", fontname="tiro", fontsize=10)
        p.insert_text((x, 80), who + ". A reference with a long", fontname="tiro", fontsize=10)
        p.insert_text((x + 14, 94), "title across several lines.", fontname="tiro", fontsize=10)
        p.insert_text((x + 14, 108), "Proceedings of Examples.", fontname="tiro", fontsize=10)
        p.insert_text((x, 145), "Next reference stays clear.", fontname="tiro", fontsize=10)
    for i in range(12):
        for x in (40, 570):
            p.insert_text((x, 80 + i * 14), str(101 + i), fontname="tiro", fontsize=7)
    p = doc.new_page(width=600, height=420)
    p.insert_text((72, 80), "Continuation of the same entry.", fontname="tiro", fontsize=10)
    p.insert_text((86, 94), "A short ending.", fontname="tiro", fontsize=10)
    doc.save(tmp_path / "paper.pdf")
    doc.close()
    targets = [dict(kind="cite", key=k, label="[{}]".format(i + 1), page=0,
                    box=[x + 14, 68, x + 205, 113], parts=[[0, [x + 14, 68, x + 205, 113]]])
               for i, (k, x) in enumerate([("a", 72), ("b", 330)])]
    lg = {"paper": {"main": "main.tex"}, "rounds": [{"n": 1, "build": {"pdf": "paper.pdf",
           "columns": [[295, 315], None]}}]}
    p = checks._Paper(tmp_path, lg, 1, {"blocks": []}, {"links": [], "targets": targets})
    p.bibitems = {}
    return p


def words(p, place):
    return [w[4] for _, w in p.words_in(place["page"], place["rects"])]


@pytest.mark.parametrize("kind", ["entry", "entries", "same_work"])
def test_whole_reference_checks_use_its_text_lines(paper, kind):
    p = paper
    if kind == "entry":
        c = checks._entry(p, "no_year", "a", "Year missing", "No year", "Check the year")
    elif kind == "entries":
        c = checks._entries(p, "venue_style", [{"key": "a", "label": "[1]"}], "Venue style", "Mixed", "Check", "venues")
    else:
        c = checks._same(p, ["a", "b"], "Duplicate", "Example")
    first = c["places"][0]
    assert len(first["rects"]) == 3
    assert words(p, first)[:2] == ["Di", "Doe."]  # Di lies entirely outside the old indented box
    assert "Previous" not in words(p, first) and "Next" not in words(p, first) and "Bo" not in words(p, first)
    assert not any(w.isdigit() for w in words(p, first))  # margin line numbers
    a, b, z = first["rects"]
    assert a[0] < b[0] and z[2] < p.targets[0]["box"][2]  # hanging start and ragged ending
    assert a[3] < b[1] and b[3] < z[1]  # line spacing stays unfilled
    if kind == "same_work":
        assert words(p, c["places"][1])[:2] == ["Bo", "Roe."]
        assert "Di" not in words(p, c["places"][1])


def test_entry_spanning_pages_marks_every_part(paper):
    paper.targets[0]["parts"].append([1, [86, 68, 280, 100]])
    c = checks._entry(paper, "no_venue", "a", "Venue missing", "No venue", "Check")
    assert [p["page"] for p in c["places"]] == [0, 1]
    assert [len(p["rects"]) for p in c["places"]] == [3, 2]
    assert words(paper, c["places"][1])[0] == "Continuation"


def test_specific_word_marks_are_preserved(paper):
    rect = list(paper.doc[0].search_for("Proceedings")[0])
    c = checks._entry(paper, "lowered_caps", "a", "Case", "Details", "Check", rects=[rect], place_text="Proceedings")
    assert c["places"] == [checks._place(0, [rect], "Proceedings")]


def test_missing_text_has_no_filled_block_and_box_only_targets_work(paper):
    del paper.targets[0]["parts"]
    c = checks._entry(paper, "no_year", "a", "Year missing", "No year", "Check")
    assert len(c["places"][0]["rects"]) == 3
    paper.targets[0]["box"] = [72, 350, 270, 380]
    c = checks._entry(paper, "no_year", "a", "Year missing", "No year", "Check")
    assert c["places"] == [checks._place(0, [], None)]


def test_without_hyperref_uses_the_bibitem_parts(paper):
    paper.blocks = [{"kind": "bibitem", "parts": paper.targets[0]["parts"]}]
    paper.targets = []
    paper.bibitems = {"a": (0, "A synthetic entry")}
    c = checks._entry(paper, "no_year", "a", "Year missing", "No year", "Check")
    assert len(c["places"][0]["rects"]) == 3
    assert words(paper, c["places"][0])[0] == "Di"
