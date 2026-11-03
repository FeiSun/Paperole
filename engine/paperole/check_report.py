"""The latest scan's execution record, kept with checks.json; never inferred from an empty findings list.

Rules still run as before. Coverage describes their inputs and conservative scope, not a guarantee that the paper
is correct. Settings filter the report at the API boundary, just as they filter findings.
"""
from datetime import datetime, timezone


TITLES = {
    "undefined_ref": "Undefined cross-references", "undefined_cite": "Undefined citations",
    "label_twice": "Duplicate labels", "float_unreferenced": "Unreferenced figures and tables",
    "float_before": "Figures and tables too far before their first citation",
    "float_far": "Figures and tables too far after their first citation",
    "same_work": "Duplicate bibliography entries", "lowered_caps": "Unprotected title capitals",
    "no_year": "Missing publication years", "no_venue": "Missing publication venues",
    "venue_forms": "Inconsistent venue names", "venue_style": "Inconsistent venue formatting",
    "author_names": "Inconsistent author names", "author_case": "Author name capitalization",
    "title_case": "Inconsistent title capitalization", "etal_by_hand": "Manually written et al.",
    "leftovers": "Stray bibliography characters", "field_mix": "Inconsistent bibliography fields",
    "page_dash": "Page-range dashes", "arxiv_forms": "Inconsistent arXiv references",
    "published_preprint": "Published versions of preprints", "no_record": "References with no online record",
    "record_differs": "Bibliography and online metadata differences", "spelling": "Inconsistent spelling",
    "ref_style": "Inconsistent cross-reference wording", "overfull": "Overfull lines",
    "straight_quotes": "Straight quotation marks", "doubled_word": "Repeated words",
    "short_last_line": "Short last lines", "paragraph_break": "Single-line paragraph breaks",
    "heading_break": "Hanging headings", "split_phrase": "Split references and units",
    "sentence_start": "Sentence openings", "type3_font": "Type 3 fonts",
    "unembedded_font": "Unembedded fonts", "draft_marker": "Draft markers", "todo_note": "Printed TODO notes",
    "coloured_text": "Coloured text", "pdf_author": "Author names in PDF metadata",
    "author_block": "Visible author blocks", "acknowledgements": "Acknowledgements in anonymous submissions",
    "personal_url": "Links that may identify an author",
}
ONLINE = {"published_preprint", "no_record", "record_differs"}
ANONYMOUS = {"pdf_author", "author_block", "acknowledgements", "personal_url"}
LAYOUT = {"short_last_line", "paragraph_break", "heading_break", "split_phrase", "sentence_start"}
SCOPES = {
    "references": "Cross-references in the source, build log and mapped PDF.",
    "bibliography": "Cited entries and the bibliography as printed; only supported entry formats and comparisons.",
    "consistency": "Recognised wording patterns in body text; not a general spelling or grammar check.",
    "typesetting": "Recognised source and PDF patterns; only text the engine can map.",
    "submission": "The built PDF and supported source patterns.",
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def record(p, code, group, count, error=None, table=True, entries_failed=False):
    row = {"code": code, "group": group, "title": TITLES.get(code, code), "count": count,
           "status": "done", "detail": SCOPES[group], "online": code in ONLINE}
    if error is not None:
        # Exception messages can contain paths or source text. The normal engine log retains diagnostics.
        row.update(status="failed", detail="The check could not finish ({}).".format(type(error).__name__))
        return row
    try:
        status, detail = _coverage(p, code, group, table, entries_failed)
        if detail:
            row.update(status=status, detail=detail)
    except Exception:
        row.update(status="unavailable", detail="The check ran, but its coverage could not be determined.")
    return row


def _coverage(p, code, group, table, entries_failed):
    if code in ANONYMOUS:
        if not p.anonymous:
            return "skipped", "The source does not select a recognised anonymous submission mode."
        return "done", "Recognised anonymous submission mode; checks supported source and PDF patterns."
    if group == "bibliography":
        if entries_failed:
            return "unavailable", "The cited bibliography entries could not be read."
        if not p.entries:
            return ("unavailable", "Citations exist, but their bibliography entries could not be read.") if p.cited else \
                ("skipped", "No cited bibliography entries.")
        if code in ONLINE:
            es = [e for e in p.entries if e["preprint"]] if code == "published_preprint" else p.entries
            if not es:
                return "skipped", "No cited preprints."
            n = sum(p.result("semantic_scholar", e["key"]) is not None for e in es)
            return ("done" if n == len(es) else "partial" if n else "unavailable"), \
                "Semantic Scholar results available for {} of {} relevant entries; only saved online results are checked.".format(n, len(es))
        n = sum(bool(e.get("printed")) for e in p.entries)
        if n < len(p.entries):
            return "partial" if n else "unavailable", \
                "Printed text available for {} of {} cited entries; checks requiring it have limited coverage.".format(n, len(p.entries))
    if code in LAYOUT:
        bs = [b for b in p.blocks[:p.refs_start] if b["kind"] == "paragraph"]
        n = sum(bool(p.parts(b)) for b in bs)
        return ("done" if n == len(bs) and n else "partial" if n else "unavailable"), \
            "{} of {} body paragraphs mapped before the bibliography. Only clear, supported patterns are reported.".format(n, len(bs))
    if code in {"float_unreferenced", "float_before", "float_far", "ref_style"} and not table:
        return "unavailable", "The PDF link table is unavailable; reference coverage is incomplete."
    if code in {"undefined_ref", "undefined_cite", "label_twice", "overfull"} and not (p.build / (p.stem + ".log")).is_file():
        return "unavailable", "The build log is unavailable."
    if code in {"float_before", "float_far"}:
        return "done", "Figures, tables and algorithms at least two pages from their first citation; teaser and appendix exemptions apply."
    return "done", None


def selected(report, groups, disabled):
    """Keep every rule visible, including exclusions. The cache itself is independent of settings."""
    if report is None:
        return None
    return dict(report, rules=[dict(r, status="off", detail="Excluded by the check settings for this round.", count=0)
                               if r["group"] not in groups or r["code"] in disabled else r for r in report["rules"]])


def failed(found):
    """An execution failure cannot establish that a previously reported problem was fixed."""
    return {r["code"] for r in (found.get("report") or {}).get("rules", ()) if r["status"] == "failed"}
