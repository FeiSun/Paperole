"""Round 1 end to end through `paperole rpc`: JSON lines on stdin/stdout of a spawned process."""
import pymupdf

from conftest import FIXTURE, TITLE, Engine, burned, equation_rect, select


def test_round1_rpc(tmp_path):
    paper = str(tmp_path / "paper")
    eng = Engine()
    try:
        state = eng.call("new", paper=paper, title=TITLE, student="Lin Zhou")["state"]
        assert state["round"] is None and state["paper"]["path"] == paper
        assert state["summary"] == {"round": None, "closed": False, "status": None, "to_judge": 0, "to_check": 0,
                                    "closed_at": None, "resumable": False}

        state = eng.call("ingest", paper=paper, source=str(FIXTURE / "v1"))["state"]
        assert "Compiling with pdflatex…" in eng.events
        assert state["round"]["build"]["status"] == "ok" and state["round"]["build"]["pages"] == 4
        pdf = state["round"]["build"]["pdf"]

        rects = select(pdf, 0, "rate from 18.4% to 6.1% while using 22% less idle memory")
        r = eng.call("comment", paper=paper, page=0, rects=rects,
                     text="rate from 18.4% to 6.1%…", note="数字要和表 1 一致。", kind="highlight")
        assert r["id"] == "R1-01"
        c = r["state"]["comments"][0]
        assert c["new_quote"] == "rate from 18.4\\% to 6.1\\% while using 22\\% less idle memory"
        assert (c["line"], c["method"], c["note"]) == (25, "selection", "数字要和表 1 一致。")

        # a citation renders as "[7]": the words match the source without it, and the range takes in the \cite
        r = eng.call("comment", paper=paper, page=0, rects=select(pdf, 0, "pay only for the time they run [7]."),
                     text="", note="cite", kind="strikeout")
        c = next(c for c in r["state"]["comments"] if c["id"] == r["id"])
        assert (c["kind"], c["method"], c["confidence"], c["line"]) == ("strikeout", "selection", 1.0, 33)
        assert c["new_quote"] == "pay only for the time they run~\\cite{jonas2019cloud}."

        rects = select(pdf, 1, "which performed best on a held-out day of the trace.")
        r = eng.call("comment", paper=paper, page=1, rects=rects,
                     text="", note="只用一天调参够吗？", kind="note")
        c = next(c for c in r["state"]["comments"] if c["id"] == r["id"])
        assert (c["file"], c["line"], c["kind"]) == ("sections/method.tex", 20, "note")

        r = eng.call("comment", paper=paper, page=1, rects=[equation_rect(pdf, 1, "C(k)")], text="", note="Eq. 2",
                     kind="highlight")
        c = next(c for c in r["state"]["comments"] if c["id"] == r["id"])
        assert c["new_quote"].startswith("\\begin{equation}") and c["line"] == 28

        r = eng.call("comment", paper=paper, page=2, rects=select(pdf, 2, "1240"), text="1240", note="?", kind="highlight")
        assert next(c for c in r["state"]["comments"] if c["id"] == r["id"])["new_quote"] == "1240"
        assert r["id"] == "R1-05"

        assert eng.call("edit_comment", paper=paper, id="R1-05", note="单位？")["state"]["comments"][-1]["note"] == "单位？"
        state = eng.call("delete_comment", paper=paper, id="R1-05")["state"]
        assert [c["id"] for c in state["comments"]] == ["R1-01", "R1-02", "R1-03", "R1-04"]

        assert "earlier rounds" in eng.error("verdict", paper=paper, id="R1-01", verdict="verified")
        assert "Unknown verdict" in eng.error("verdict", paper=paper, id="R1-01", verdict="done")
        assert "Missing parameter: page" in eng.error("comment", paper=paper, rects=[[1, 1, 2, 2]])
        assert "Unknown method" in eng.error("rebuild", paper=paper)
        assert "not a Paperole paper folder" in eng.error("state", paper=str(tmp_path))
        eng.send("this is not json")
        assert "not valid JSON" in eng.reply(None)["error"]["message"]

        state = eng.call("state", paper=paper)["state"]
        assert set(state) == {"schema", "paper", "rounds", "round", "comments", "changes", "note_warnings", "summary",
                              "reading", "tag_names"}
        assert set(state["round"]) == {"n", "closed", "created", "closed_at", "build", "final_pdf", "email",
                                       "resumable", "finishes"}
        assert set(state["round"]["build"]) == {"status", "pdf", "pages", "text_x", "columns", "rulers", "warnings",
                                                 "errors", "log_tail"}
        assert set(state["rounds"][0]) == {"n", "created", "source", "closed", "closed_at", "status", "pdf"}
        assert all(set(c) == {"id", "kind", "color", "note", "source", "created_round", "carried", "verdict",
                              "verdict_note", "anchor_state", "confidence", "method", "page", "rects", "text",
                              "old_quote", "new_quote", "file", "line", "changes", "student_note", "context", "history",
                              "paragraph", "tags", "env", "revived", "revivable"}
                   for c in state["comments"])
        assert all(set(c["context"]) == {"display", "page", "rects", "clip", "text", "sel", "cut", "changed",
                                         "against"} for c in state["comments"])
        assert [c["context"]["display"] for c in state["comments"]] == ["text", "text", "text", "image"]

        r = eng.call("reanchor", paper=paper, id="R1-02", page=0, rects=select(pdf, 0, "simple keep-alive policy:"),
                     kind="underline")
        c = next(c for c in r["state"]["comments"] if c["id"] == "R1-02")
        assert (c["kind"], c["note"], c["new_quote"]) == ("underline", "cite", "simple keep-alive policy:")
        r = eng.call("edit_comment", paper=paper, id="R1-02", color="purple")
        assert next(c for c in r["state"]["comments"] if c["id"] == "R1-02")["color"] == "purple"
        assert "Unknown comment kind" in eng.error("reanchor", paper=paper, id="R1-02", page=0, rects=[[1, 1, 2, 2]],
                                                   kind="wavy")
        assert "Output written" in state["round"]["build"]["log_tail"]

        state = eng.call("finish", paper=paper)["state"]
        assert state["round"]["closed"] and state["round"]["email"].count("\nR1-0") == 4
        final = pymupdf.open(state["round"]["final_pdf"])
        assert all(a.type[1] == "Link" for p in final for a in p.annots())  # the marks are burned in
        kinds = {c["id"]: {k for k, _ in burned(final[c["page"] + 1], c["rects"])} for c in state["comments"]}
        assert ("highlight" in kinds["R1-01"] & kinds["R1-04"] and "underline" in kinds["R1-02"]
                and "note" in kinds["R1-03"])
        assert "数字要和表 1 一致。" in final[0].get_text()
    finally:
        code, rest = eng.close()
    assert code == 0 and rest == ""


def test_a_folder_that_is_no_paper_and_a_ledger_cut_short(tmp_path):
    """Plain words, never "Internal error" or a path to .lock; and no .lock made in a folder without a ledger."""
    eng = Engine()
    try:
        gone, empty, paper = tmp_path / "gone", tmp_path / "empty", tmp_path / "paper"
        empty.mkdir()
        for folder in (gone, empty):
            message = eng.error("edit_paper", paper=str(folder), title="T")
            assert message == "{} is not a Paperole paper folder (no ledger.json).".format(folder)
        assert not gone.exists() and list(empty.iterdir()) == []

        eng.call("new", paper=str(paper), title=TITLE, student="Lin Zhou")
        raw = (paper / "ledger.json").read_bytes()
        (paper / "ledger.json").write_bytes(raw[:len(raw) // 2])  # cut short
        for method, params in (("state", {}), ("edit_paper", {"title": "T"})):
            assert eng.error(method, paper=str(paper), **params) == \
                "ledger.json cannot be read. Put back an earlier ledger."
    finally:
        code, rest = eng.close()
    assert code == 0 and rest == ""
