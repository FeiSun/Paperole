"""References (refs.py and the bibliography's format and online checks of checks.py; CONTRACT.md amendment
"References"): the cited entries' fields, each format check on a synthetic paper whose style prints the slips and on its
twin whose style hides them (abbrv: initials, lower-case titles, no DOI), and its clean twin; the references and
ref_results RPCs and the CLI, results merged and refused, the online checks from stored results, and checks.json
built again when the results change."""
import json
import os
import shutil
import subprocess
import sys

import pymupdf
import pytest

from conftest import Engine, quiet
from paperole import api, checks, disk, prose, refs, render

PATH = "/Library/TeX/texbin" + os.pathsep + os.environ.get("PATH", "")
pytestmark = pytest.mark.skipif(not shutil.which("latexmk", path=PATH), reason="needs latexmk and synctex")

SOURCE = r"""\documentclass{article}
\usepackage{url}
%(hyperref)s
\begin{document}
\section{Related work}
Pools were studied before \cite{%(keys)s}.

%(bibliography)s
\end{document}
"""

# Thirteen entries. MIXED's slips, each a clear minority: one NeurIPS written in full (n1), a journal in full (a1),
# ICML's entry without its DOI and in sentence case (m1), initials (c1), a lower-case author (x1), a list cut to "and
# others" (x2) while a1 prints its five authors, a stray "{" (x3), a typed spacing accent (x4, beside n1's \"o, which
# TeX sets over its letter) and CoRR's form of an arXiv id (x4).
MIXED = r"""
@inproceedings{n1, author = {Bernhard Sch{\"o}lkopf and Alice Wang}, title = {Sparse Attention Models for Long Documents},
  booktitle = {Advances in Neural Information Processing Systems}, year = {2020}, pages = {1--10},
  doi = {10.5555/1000001}}
@inproceedings{n2, author = {Carol Diaz and Dan Evans}, title = {Warm Starts for Serverless Inference},
  booktitle = {NeurIPS}, year = {2021}, pages = {11--20}, doi = {10.5555/1000002}}
@inproceedings{n3, author = {Erin Ford}, title = {Cold Pools Considered Harmful}, booktitle = {NeurIPS},
  year = {2021}, pages = {21--30}, doi = {10.5555/1000003}}
@inproceedings{n4, author = {Frank Green and Grace Hall}, title = {Predicting Idle Memory with Small Models},
  booktitle = {NeurIPS}, year = {2022}, pages = {31--40}, doi = {10.5555/1000004}}
@inproceedings{i1, author = {Henry Irwin}, title = {Learning Pool Sizes from Request Traces}, booktitle = {ICLR},
  year = {2022}, pages = {41--50}, doi = {10.5555/1000005}}
@inproceedings{i2, author = {Iris Jones}, title = {Scheduling Sandboxes Across Many Machines}, booktitle = {ICLR},
  year = {2023}, pages = {51--60}, doi = {10.5555/1000006}}
@inproceedings{m1, author = {Jack King}, title = {Faster sandboxes through careful snapshots}, booktitle = {ICML},
  year = {2023}, pages = {61--70}}
@inproceedings{c1, author = {A. Kim and B. Park}, title = {Visual Models of Request Arrival}, booktitle = {CVPR},
  year = {2023}, pages = {71--80}, doi = {10.5555/1000008}}
@article{a1, author = {Kate Lowe and Liam Moss and Mia Nash and Noah Ortiz and Olga Price},
  title = {Queueing Theory for Function Platforms}, journal = {Journal of Machine Learning Research}, year = {2021},
  volume = {22}, pages = {1--30}, doi = {10.5555/1000009}}
@article{x1, author = {kaiming he and Paul Quinn}, title = {Memory Snapshots Make Functions Fast},
  journal = {arXiv preprint arXiv:2001.00001}, year = {2020}}
@article{x2, author = {Rosa Stone and others}, title = {Billing Models for Elastic Platforms},
  journal = {arXiv preprint arXiv:2001.00002}, year = {2020}}
@article{x3, author = {Sam Turner}, title = {Bounded Queues \{Revisited\} for Modern Clusters},
  journal = {arXiv preprint arXiv:2001.00003}, year = {2020}}
@article{x4, author = {Tina Sch¨olkopf}, title = {Container Images Without Their Layers}, journal = {CoRR},
  volume = {abs/2001.00004}, year = {2020}}
"""
KEYS = "n1,n2,n3,n4,i1,i2,m1,c1,a1,x1,x2,x3,x4"
CLEAN = MIXED.replace("Advances in Neural Information Processing Systems", "NeurIPS") \
    .replace("Journal of Machine Learning Research", "JMLR") \
    .replace("Faster sandboxes through careful snapshots", "Faster Sandboxes Through Careful Snapshots") \
    .replace("pages = {61--70}}", "pages = {61--70}, doi = {10.5555/1000007}}") \
    .replace("A. Kim and B. Park", "Alma Kim and Ben Park").replace("kaiming he", "Kaiming He") \
    .replace("Rosa Stone and others", "Rosa Stone and Uma Vance and Vera White and Will Young") \
    .replace("\\{Revisited\\}", "Revisited").replace("Sch¨olkopf", "Sch{\\\"o}lkopf") \
    .replace("journal = {CoRR},\n  volume = {abs/2001.00004}", "journal = {arXiv preprint arXiv:2001.00004}")
NEW = {"venue_forms", "venue_style", "author_names", "author_case", "title_case", "etal_by_hand", "leftovers",
       "field_mix", "page_dash", "arxiv_forms", "published_preprint", "no_record", "record_differs"}

# a hand-written list without a .bib: its fields from the bibitems; one page range with a hyphen among dashes
BIBITEMS = r"""\begin{thebibliography}{9}
\bibitem{b1} A.~Wang and B.~Li.
\newblock Cold starts in practice.
\newblock In \emph{Proc. X}, pages 1--5, 2021.
\bibitem{b2} C.~Chen.
\newblock Serverless in the wild.
\newblock \emph{J. Y}, pages 6--9, 2020.
\bibitem{b3} D.~Ito.
\newblock Pricing idle memory.
\newblock \emph{J. W}, pages 10--19, 2019.
\bibitem{b4} E.~Fox.
\newblock Warm pools.
\newblock \emph{J. W}, pages 20--29, 2018.
\bibitem{b5} F.~Gray.
\newblock Snapshots of functions.
\newblock arXiv:2101.00005, \url{https://doi.org/10.5555/2000005}, pages 30-39, 2017.
\end{thebibliography}"""


def _paper(root, bib, style, hyperref=True):
    """A round-1 paper citing KEYS from bib in a BibTeX style, or (bib None) BIBITEMS' entries."""
    src = root / "src"
    src.mkdir(parents=True)
    (src / "main.tex").write_text(SOURCE % {
        "hyperref": "\\usepackage{hyperref}" if hyperref else "", "keys": KEYS if bib else "b1,b2,b3,b4,b5",
        "bibliography": "\\bibliographystyle{{{}}}\n\\bibliography{{refs}}".format(style) if bib else BIBITEMS})
    if bib:
        (src / "refs.bib").write_text(bib, encoding="utf-8")
    paper = root / "paper"
    api.new({"paper": str(paper), "title": "Pools", "student": "Lin Zhou"}, quiet)
    api.ingest({"paper": str(paper), "source": str(src)}, quiet)
    return paper


@pytest.fixture(scope="module")
def mixed(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("mixed"), MIXED, "ACM-Reference-Format")


@pytest.fixture(scope="module")
def hidden(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("hidden"), MIXED, "abbrv", hyperref=False)


def test_whole_entry_line_highlights_reach_the_export(mixed, tmp_path):
    paper = tmp_path / "paper"
    shutil.copytree(mixed, paper)
    found = api.checks_({"paper": str(paper)}, quiet)["checks"]
    finding = next(c for c in found if c["code"] == "venue_forms")
    place, = finding["places"]
    assert len(place["rects"]) > 1
    assert all(r[3] - r[1] < 16 for r in place["rects"])
    api.check_items_({"paper": str(paper), "disabled": [c for c in checks.CODES if c != "venue_forms"]}, quiet)
    state = api.finish({"paper": str(paper), "checks": True}, quiet)["state"]
    final = paper / "r1/final.pdf"
    with pymupdf.open(final) as doc:
        page = doc[len(doc) - state["round"]["build"]["pages"] + place["page"]]
        colour = render._rgb(render.CHECK_FILL)
        marks = [d["rect"] for d in page.get_drawings() if d.get("fill")
                 and all(abs(a - b) < 0.01 for a, b in zip(d["fill"], colour))]
        assert len(marks) == len(place["rects"])
        assert all(any(all(abs(a - b) < 0.02 for a, b in zip(r, drawn)) for drawn in marks) for r in place["rects"])
    if os.environ.get("PAPEROLE_TEXT_MARKS_OUT"):
        shutil.copyfile(final, os.path.join(os.environ["PAPEROLE_TEXT_MARKS_OUT"], "bibliography-highlights.pdf"))


@pytest.fixture(scope="module")
def clean(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("clean"), CLEAN, "ACM-Reference-Format")


@pytest.fixture(scope="module")
def items(tmp_path_factory):
    return _paper(tmp_path_factory.mktemp("items"), None, None, hyperref=False)


@pytest.fixture
def copy(tmp_path):
    def make(paper):
        dest = tmp_path / "copy"
        shutil.copytree(paper, dest)
        return dest
    return make


def _checks(paper):
    return api.checks_({"paper": str(paper)}, quiet)["checks"]


def _by_code(found):
    out = {}
    for c in found:
        out.setdefault(c["code"], []).append(c)
    return out


def _labels(paper, c):
    """The keys of a check's places (each an entry's place, its text the entry's label)."""
    by_label = {e["label"]: e["key"] for e in api.references({"paper": str(paper)}, quiet)["entries"]}
    return sorted(by_label[p["text"]] for p in c["places"])


def test_the_entries_fields(mixed):
    reply = api.references({"paper": str(mixed)}, quiet)
    assert set(reply) == {"round", "entries", "results", "attempts"} and reply["round"] == 1 and reply["results"] == {}
    assert reply["attempts"] == {}
    entries = {e["key"]: e for e in reply["entries"]}
    assert list(entries) == KEYS.split(",")  # in citation order
    for e in entries.values():
        assert set(e) == {"key", "label", "type", "title", "authors", "year", "venue", "arxiv", "doi", "pages", "url",
                          "preprint", "printed", "place"}
        assert isinstance(e["place"]["page"], int) and e["place"]["rects"] and e["place"]["text"] == e["label"]
    n1, x2, x4 = entries["n1"], entries["x2"], entries["x4"]
    assert n1["type"] == "inproceedings" and n1["title"] == "Sparse Attention Models for Long Documents"
    assert n1["authors"] == ["Bernhard Schölkopf", "Alice Wang"] and n1["year"] == "2020"
    assert n1["venue"] == "Advances in Neural Information Processing Systems" and n1["doi"] == "10.5555/1000001"
    assert n1["pages"] == "1–10" and n1["arxiv"] is None and n1["preprint"] is False and n1["url"] is None
    assert "Sparse Attention Models for Long Documents" in n1["printed"]
    assert x2["authors"] == ["Rosa Stone"] and x2["arxiv"] == "2001.00002" and x2["preprint"] is True
    assert x4["venue"] == "CoRR" and x4["arxiv"] == "2001.00004" and x4["preprint"] is True
    assert refs.load(mixed, 1)["entries"] == reply["entries"]  # kept in refs.json, outside the round's checksums
    assert "refs.json" not in disk.round_files(mixed / "r1", "main")


def test_fields_from_a_bib_without_tex():
    """arXiv's forms, the DOI, Paperlib's preprint rule and the names, from .bib fields alone."""
    p = type("P", (), {"ctx": prose._Ctx({}, ({}, {}, {}), False)})()
    get = lambda **f: refs._from_bib(p, f)  # noqa: E731
    assert get(eprint="2010.11929v2", archiveprefix="arXiv")["arxiv"] == "2010.11929"
    assert get(eprint="2010.11929", eprinttype="arxiv")["arxiv"] == "2010.11929"
    assert get(journal="arXiv preprint arXiv:2010.11929")["arxiv"] == "2010.11929"
    assert get(journal="CoRR", volume="abs/2010.11929")["arxiv"] == "2010.11929"
    assert get(url="https://arxiv.org/abs/2010.11929v3")["arxiv"] == "2010.11929"
    assert get(eprint="hep-th/9901001", archiveprefix="arXiv")["arxiv"] == "hep-th/9901001"
    assert get(journal="Journal of X", volume="abs/2010.11929")["arxiv"] is None  # abs/ is CoRR's only
    assert get(doi="https://doi.org/10.1145/3292500.3330701")["doi"] == "10.1145/3292500.3330701"
    assert get(url="https://doi.org/10.1000/xyz.")["doi"] == "10.1000/xyz"
    assert get(date="2021-05-01")["year"] == "2021" and get(year="2020", date="2021")["year"] == "2020"
    assert get(author="{Google Research} and Smith, J. and others")["authors"] == ["Google Research", "Smith, J."]
    assert get(booktitle="NeurIPS", publisher="Curran")["venue"] == "NeurIPS"
    assert refs.names("A {B and C} and D and others") == ["A {B and C}", "D", "others"]
    assert refs.name_parts("Dosovitskiy, Alexey") == ("Alexey", "Dosovitskiy")
    assert refs.name_parts("Laurens van der Maaten") == ("Laurens", "van der Maaten")
    assert refs.name_parts("{Google Research}") == ("", "{Google Research}")
    for venue, preprint in (("", True), ("arXiv preprint arXiv:1", True), ("OpenReview.net", True), ("CoRR", True),
                            ("bioRxiv", True), ("Corrective Optics", False), ("ICLR", False)):
        assert bool(not venue or refs.PREPRINT.search(venue)) is preprint, venue


def test_venue_rules():
    fold = refs.fold_venue
    icml = fold("In Proceedings of the 34th International Conference on Machine Learning (ICML 2017)")
    assert icml == "international conference on machine learning icml" and refs.venue_name(icml) == "ICML"
    for venue in ("NIPS", "Advances in Neural Information Processing Systems 33", "NeurIPS'20", "Proc. NeurIPS"):
        assert refs.venue_name(fold(venue)) == "NeurIPS", venue
    assert refs.venue_name(fold("NeurIPS Workshop on Systems")) == "neurips workshop on systems"  # not NeurIPS
    assert refs.venue_name(fold("Transactions of the Association for Computational Linguistics")) == "TACL"
    assert [refs.venue_form(v) for v in ("ICLR", "ICLR 2021", "NeurIPS", "Proc. NAACL", "In CVPR",
                                         "International Conference on Learning Representations", "J. Y", "Nature",
                                         "Proc. X", "ABCDEFGHI")] == \
        ["short", "short", "short", "short", "short", "full", None, None, None, None]


def test_minority_rule():
    one, two, three = [1], [1, 2], [1, 2, 3]
    assert checks._minority({"a": three, "b": one}) == {"b": one}  # 4 compared, a quarter
    assert checks._minority({"a": two, "b": one}) is None  # 3 compared: too few
    assert checks._minority({"a": [1] * 4, "b": two}) == {"b": two}  # a third
    assert checks._minority({"a": [1] * 4, "b": three}) is None  # more than a third
    assert checks._minority({"a": [1] * 8, "b": []}) is None  # one way only
    assert checks._minority({"a": [1] * 6, "b": one, "c": two}) == {"b": one, "c": two}


def test_format_checks_on_the_mixed_paper(mixed):
    by = _by_code(_checks(mixed))
    assert NEW - {"page_dash", "published_preprint", "no_record", "record_differs"} <= set(by)
    assert "page_dash" not in by  # BibTeX's styles print every range with a dash
    forms, = by["venue_forms"]
    assert forms["text"] == "One venue written two ways · NeurIPS · Advances in Neural Information Processing Systems"
    assert forms["key"] == "venue_forms|neurips" and _labels(mixed, forms) == ["n1"]
    assert forms["detail"] == "The references write one venue two ways: “NeurIPS” (3×) and “Advances in Neural " \
                              "Information Processing Systems” (1×)."
    style, = by["venue_style"]
    # conference papers only: the journal a1 in full is not compared (review 2026-11-01)
    assert style["text"] == "Venues: 7 short, 1 in full" and _labels(mixed, style) == ["n1"]
    assert style["key"] == "venue_style|venues"
    names, = by["author_names"]
    assert names["text"] == "Authors: 12 entries with full first names, 1 with initials"
    assert _labels(mixed, names) == ["c1"] and names["key"] == "author_names|first names"
    case, = by["author_case"]
    assert case["text"].startswith("Author name in lower case · kaiming he · ") and case["key"] == "author_case|x1"
    assert case["places"][0]["text"] == "kaiming he"
    titles, = by["title_case"]
    assert titles["text"] == "Titles: 12 in title case, 1 in sentence case" and _labels(mixed, titles) == ["m1"]
    etal, = by["etal_by_hand"]
    assert etal["text"].startswith("Author list cut to “et al.” · ") and etal["key"] == "etal_by_hand|x2"
    stray = {c["key"]: c for c in by["leftovers"]}
    # not n1's ö, which TeX sets as a ¨ over its o
    assert set(stray) == {"leftovers|x3|{", "leftovers|x3|}", "leftovers|x4|¨"}
    assert stray["leftovers|x3|{"]["text"].startswith("Stray “{” · ")
    assert stray["leftovers|x3|{"]["places"][0]["text"] == "{Revisited}"
    assert all("Sch¨olkopf" in p["text"] for p in stray["leftovers|x4|¨"]["places"])  # the label and the name
    field, = by["field_mix"]
    assert field["text"] == "DOI missing on 1 of 8 conference papers" and _labels(mixed, field) == ["m1"]
    assert field["key"] == "field_mix|inproceedings|doi"
    assert field["detail"] == "1 of 8 conference papers print no DOI; the other 7 do."
    arxiv, = by["arxiv_forms"]
    assert arxiv["text"] == "arXiv written two ways · arXiv:2001.00001 · CoRR abs/2001.00004"
    assert _labels(mixed, arxiv) == ["x4"] and arxiv["key"] == "arxiv_forms|arxiv"
    for c in sum(by.values(), []):
        assert c["group"] == checks.CODES[c["code"]] and c["detail"] and c["note"] and c["places"]


def test_a_style_that_hides_a_field_reports_nothing(hidden):
    """abbrv prints initials, lower-case titles and no DOI: no author_names, title_case or field_mix; the slips it still
    prints are found, from the bibitem blocks without hyperref."""
    by = _by_code(_checks(hidden))
    assert not {"author_names", "title_case", "field_mix"} & set(by)
    assert {"venue_forms", "venue_style", "author_case", "etal_by_hand", "leftovers", "arxiv_forms"} <= set(by)
    assert by["author_case"][0]["text"].startswith("Author name in lower case · kaiming he · ")


def test_the_clean_twin_has_none(clean):
    assert not NEW & {c["code"] for c in _checks(clean)}


def test_entries_from_bibitems_and_page_dashes(items):
    entries = {e["key"]: e for e in api.references({"paper": str(items)}, quiet)["entries"]}
    b1, b5 = entries["b1"], entries["b5"]
    assert b1["type"] is None and b1["authors"] == ["A. Wang", "B. Li"] and b1["title"] == "Cold starts in practice"
    assert b1["venue"] == "Proc. X" and b1["year"] == "2021" and b1["pages"] == "1–5" and b1["preprint"] is False
    assert b5["arxiv"] == "2101.00005" and b5["doi"] == "10.5555/2000005" and b5["venue"] is None
    assert b5["url"] == "https://doi.org/10.5555/2000005" and b5["pages"] == "30-39" and b5["preprint"] is True
    dash, = _by_code(_checks(items))["page_dash"]
    assert dash["text"] == "Page ranges: 4 with a dash, 1 with a hyphen" and _labels(items, dash) == ["b5"]
    assert dash["key"] == "page_dash|pages"


RESULTS = {
    "x1": {"found": True, "title": "Memory snapshots make functions fast", "year": 2021, "venue": "ICLR",
           "authors": ["Kaiming He", "Paul Quinn"], "citations": 12, "url": "https://example.org/x1", "doi": None,
           "arxiv": "2001.00001", "record": "s1", "published": "ICLR 2021", "closest": None},
    "x3": {"found": False, "closest": {"title": "Bounded Queues", "year": 2019, "authors": ["S. Turner"]}},
    "x2": {"found": False, "closest": None},
    "n1": {"found": True, "title": "Sparse attention for long documents", "year": 2015, "authors": ["Ann Other"],
           "record": "s2", "published": "NeurIPS"},
    "i1": {"found": True, "title": "Learning pool sizes from request traces", "year": 2023,
           "authors": ["Henry Irwin"], "record": "s3", "published": "ICLR"},
    "i2": {"found": True, "title": "Scheduling Sandboxes Across Many Machines", "year": 2023,
           "authors": ["Iris Jones"], "record": "s4", "published": "ICLR"},
    "x4": {"found": True, "title": "Container images without their layers", "year": 2020, "authors": ["T. Schölkopf"],
           "record": "s4", "published": None},
}


def test_online_checks_from_stored_results(mixed, copy):
    paper = copy(mixed)
    before = _checks(paper)
    assert not {"published_preprint", "no_record", "record_differs"} & {c["code"] for c in before}
    assert api.ref_results({"paper": str(paper), "round": 1, "source": "semantic_scholar", "results": RESULTS},
                           quiet) == {"stored": 7}
    assert checks.load(paper, 1) is None  # stale: built again on the next call
    assert api.ref_results({"paper": str(paper), "round": 1, "source": "google_scholar",
                            "results": {"x2": {"found": True, "citations": 3}, "x3": {"found": False}}},
                           quiet) == {"stored": 2}
    by = _by_code(_checks(paper))
    published, = by["published_preprint"]
    assert published["text"].endswith(" arXiv preprint · published at ICLR 2021") and _labels(paper, published) == ["x1"]
    assert published["note"] == "Cite the published version (ICLR 2021)." and published["key"] == "published_preprint|x1"
    record, = by["no_record"]  # x2: Google Scholar has it
    assert record["text"].endswith(" · no record") and record["key"] == "no_record|x3"
    assert record["detail"] == "Semantic Scholar and Google Scholar find no record of “Bounded Queues {Revisited} for " \
                               "Modern Clusters”. Closest: Bounded Queues · 2019 · S. Turner."
    assert record["note"] == "Check that this work exists and that its title is right."
    differs = {c["key"]: c for c in by["record_differs"]}
    assert set(differs) == {"record_differs|n1|year", "record_differs|n1|title", "record_differs|n1|first author"}
    assert differs["record_differs|n1|year"]["text"].endswith(" · year 2020, published 2015")  # i1's one year: none
    assert differs["record_differs|n1|title"]["text"].endswith(" · title differs")
    assert differs["record_differs|n1|first author"]["text"].endswith(" · first author differs")
    same = [c for c in by["same_work"] if c["key"] == "same_work|i2 x4"]
    assert len(same) == 1 and same[0]["detail"].startswith("Semantic Scholar finds the entries i2 and x4 as one work")
    # the results come back with the entries; an earlier result for a key is replaced, the others kept
    reply = api.references({"paper": str(paper)}, quiet)
    assert reply["results"]["semantic_scholar"]["x1"] == RESULTS["x1"] and set(reply["results"]["google_scholar"]) == \
        {"x2", "x3"}
    api.ref_results({"paper": str(paper), "round": 1, "source": "semantic_scholar",
                     "results": {"x1": {"found": True, "title": "Memory Snapshots Make Functions Fast",
                                        "published": None}}}, quiet)
    stored = refs.load(paper, 1)["results"]["semantic_scholar"]
    assert stored["x1"] == {"found": True, "title": "Memory Snapshots Make Functions Fast", "published": None}
    assert set(stored) == set(RESULTS)
    assert "published_preprint" not in _by_code(_checks(paper))
    # the same results again: refs.json rewritten, checks.json still current
    built = checks.load(paper, 1)
    api.ref_results({"paper": str(paper), "round": 1, "source": "google_scholar", "results": {"x3": {"found": False}}},
                    quiet)
    assert checks.load(paper, 1) == built
    # refs.json gone or damaged: the checks (and the entries) are built again, the results with it gone
    refs.path(paper, 1).write_text("{not json")
    assert checks.load(paper, 1) is None and _checks(paper)
    assert refs.load(paper, 1)["entries"] and refs.load(paper, 1)["results"] == {}


def test_refusals(mixed, copy, tmp_path):
    paper = copy(mixed)
    call = lambda **kw: api.ref_results(dict({"paper": str(paper), "round": 1, "source": "semantic_scholar",  # noqa
                                              "results": {}}, **kw), quiet)
    with pytest.raises(Exception, match="^A result for reference nobody, which round 1 does not cite.$"):
        call(results={"nobody": {"found": False}})
    with pytest.raises(Exception, match="^source is semantic_scholar or google_scholar.$"):
        call(source="crossref")
    with pytest.raises(Exception, match="^results is a map of reference keys to results, each with found true or "
                                        "false.$"):
        call(results={"x1": {"title": "no found"}})
    with pytest.raises(Exception, match="^There is no round 4.$"):
        call(round=4)
    with pytest.raises(Exception, match="^Missing parameter: round$"):
        api.ref_results({"paper": str(paper), "source": "semantic_scholar", "results": {}}, quiet)
    assert refs.load(paper, 1)["results"] == {} and call() == {"stored": 0}
    with pytest.raises(Exception, match="^There is no round 4.$"):
        api.references({"paper": str(paper), "round": 4}, quiet)
    api.new({"paper": str(tmp_path / "empty"), "title": "Pools", "student": "Lin Zhou"}, quiet)
    with pytest.raises(Exception, match="^There is no round yet. Ingest the student's source first.$"):
        api.references({"paper": str(tmp_path / "empty")}, quiet)
    # results for a round whose entries were never built: built first
    refs.path(paper, 1).unlink(missing_ok=True)
    checks.path(paper, 1).unlink(missing_ok=True)
    assert call(results={"x1": {"found": False}}) == {"stored": 1} and checks.load(paper, 1) is None


def test_rpc_and_cli(mixed, copy, tmp_path):
    paper = copy(mixed)
    eng = Engine()
    try:
        eng.send(json.dumps({"id": 1, "method": "references", "params": {"paper": str(paper)}}))
        reply = eng.reply(1)["result"]
        assert reply == api.references({"paper": str(paper)}, quiet) and "state" not in reply
        eng.send(json.dumps({"id": 2, "method": "ref_results", "params": {
            "paper": str(paper), "round": 1, "source": "semantic_scholar", "results": {"x2": RESULTS["x2"]}}}))
        assert eng.reply(2)["result"] == {"stored": 1}
        eng.send(json.dumps({"id": 3, "method": "ref_results", "params": {
            "paper": str(paper), "round": 1, "source": "semantic_scholar", "results": {"zz": {"found": True}}}}))
        assert eng.reply(3)["error"]["message"] == "A result for reference zz, which round 1 does not cite."
    finally:
        assert eng.close()[0] == 0
    found = tmp_path / "found.json"
    found.write_text(json.dumps({"x3": RESULTS["x3"]}))
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "ref-results", str(paper), "1", "semantic_scholar",
                          str(found)], capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert out.returncode == 0 and json.loads(out.stdout) == {"stored": 1}
    out = subprocess.run([sys.executable, "-m", "paperole.cli", "references", str(paper), "--round", "1"],
                         capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert out.returncode == 0 and set(json.loads(out.stdout)["results"]["semantic_scholar"]) == {"x2", "x3"}
    assert "no_record|x3" in {c["key"] for c in _checks(paper)}
