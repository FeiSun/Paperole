"""Paper-menu eligibility follows the same rules as replacing a draft. Synthetic data only."""
import copy

import pytest

from paperole import EngineError, api, ledger, state


@pytest.mark.parametrize("work", ["new_comment", "verdict", "revived", "check_note", "empty_check_note", "resumed"])
def test_review_work_disables_and_refuses_replacement(tmp_path, work):
    paper = tmp_path / "review"
    paper.mkdir()
    ledger.create(paper, "Synthetic draft", "Test author")
    with ledger.edit(paper) as lg:
        lg["rounds"] = [{"n": 2, "created": ledger.now(), "closed": False, "closed_at": None,
                         "last_seq": 0, "build": {"status": "failed", "pdf": None}}]
        if work == "resumed":
            lg["rounds"][0]["finishes"] = [{"at": ledger.now()}]
        elif "check_note" in work:
            lg["check_items"] = {"test": {"rounds": {"2": {"advisor_note": "" if work == "empty_check_note" else "Explain."}}}}
        else:
            record = {"verdict": "verified"} if work == "verdict" else {"revived": True} if work == "revived" else {}
            lg["comments"] = [{"id": "R1-01", "created_round": 2 if work == "new_comment" else 1,
                               "rounds": {"2": record}}]
    before = (paper / "ledger.json").read_bytes()
    assert state.summary(paper, ledger.load(paper))["replaceable"] is False
    with pytest.raises(EngineError, match="Finish"):
        api.ingest({"paper": str(paper), "source": str(tmp_path / "new-source")}, lambda _: None)
    assert (paper / "ledger.json").read_bytes() == before


def test_summary_allows_unreviewed_carried_comments_and_failed_builds(tmp_path):
    lg = {"rounds": [{"n": 2, "closed": False, "closed_at": None, "build": {"status": "failed"}}],
          "comments": [{"created_round": 1, "rounds": {"1": {"verdict": "reopened"}, "2": {"verdict": None}}}]}
    assert state.summary(tmp_path, lg)["replaceable"] is True
    closed = copy.deepcopy(lg)
    closed["rounds"][0]["closed"] = True
    assert state.summary(tmp_path, closed)["replaceable"] is False
    assert state.summary(tmp_path, {"rounds": [], "comments": []})["replaceable"] is False


def test_replace_unreviewed_source_and_finish_with_zero_comments(tmp_path):
    paper, source = tmp_path / "review", tmp_path / "source"
    source.mkdir()
    main = source / "main.tex"
    main.write_text("\\documentclass{article}\n\\begin{document}\nFirst draft.\n\\end{document}\n")
    quiet = lambda _: None
    api.new({"paper": str(paper), "title": "Synthetic draft", "student": "Test author"}, quiet)
    first = api.ingest({"paper": str(paper), "source": str(source)}, quiet)["state"]
    assert first["summary"]["replaceable"] is True
    main.write_text(main.read_text().replace("First draft", "Updated draft"))
    updated = api.ingest({"paper": str(paper), "source": str(source)}, quiet)["state"]
    assert [r["n"] for r in updated["rounds"]] == [1]
    assert (paper / "r1/src/main.tex").read_text() == main.read_text()
    assert updated["comments"] == []
    finished = api.finish({"paper": str(paper)}, quiet)["state"]
    assert finished["round"]["closed"] is True
    assert finished["summary"]["replaceable"] is False
    assert (paper / "r1/final.pdf").is_file()
