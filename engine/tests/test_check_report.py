"""Execution evidence, independent of the presence of findings. Synthetic papers only."""
import json
from collections import Counter
from types import SimpleNamespace

import pytest

from paperole import EngineError, api, check_report, checks, refs
from conftest import quiet


def test_every_rule_is_recorded_and_cache_keeps_scan_time(paper):
    reply = api.checks_({"paper": str(paper)}, quiet)
    report = reply["report"]
    assert {r["code"] for r in report["rules"]} == set(checks.CODES) == set(check_report.TITLES)
    counts = Counter(c["code"] for c in reply["checks"])
    assert all(r["count"] == counts[r["code"]] for r in report["rules"])
    assert any(r["status"] == "done" and r["count"] == 0 for r in report["rules"])
    assert api.checks_({"paper": str(paper)}, quiet)["report"] == report
    assert report["started_at"] <= report["completed_at"]


def test_settings_exclusions_are_visible_without_mutating_the_scan(paper):
    before = api.checks_({"paper": str(paper)}, quiet)["report"]
    after = api.checks_({"paper": str(paper), "groups": ["typesetting"], "disabled": ["short_last_line"]}, quiet)["report"]
    assert after["completed_at"] == before["completed_at"]
    assert all(r["status"] == "off" for r in after["rules"] if r["group"] != "typesetting" or r["code"] == "short_last_line")
    assert api.checks_({"paper": str(paper)}, quiet)["report"] == before


def test_finished_round_report_uses_its_saved_selection(paper):
    api.checks_({"paper": str(paper)}, quiet)
    api.check_items_({"paper": str(paper), "groups": ["typesetting"], "disabled": ["short_last_line"]}, quiet)
    api.finish({"paper": str(paper), "checks": True}, quiet)
    report = api.checks_({"paper": str(paper), "groups": list(checks.GROUPS), "disabled": []}, quiet)["report"]
    assert all(r["status"] == "off" for r in report["rules"] if r["group"] != "typesetting" or r["code"] == "short_last_line")


def test_failed_rule_is_not_a_clean_result(paper, monkeypatch, capsys):
    def broken(_):
        raise ValueError("private source fragment that must not enter the report")
    api.checks_({"paper": str(paper)}, quiet)
    checks.path(paper, 1).unlink()
    monkeypatch.setattr(checks, "RUNS", [(code, broken if code == "spelling" else run) for code, run in checks.RUNS])
    reply = api.checks_({"paper": str(paper)}, quiet)
    rule = next(r for r in reply["report"]["rules"] if r["code"] == "spelling")
    assert rule["status"] == "failed" and rule["count"] == 0
    assert "ValueError" in rule["detail"]
    assert "private source" not in json.dumps(reply["report"])
    assert any(r["status"] == "done" for r in reply["report"]["rules"])
    assert "spelling failed" in capsys.readouterr().err
    # Do not leave the shared fixture's cache with a simulated failure.
    checks.path(paper, 1).unlink()


def test_missing_inputs_and_not_applicable_have_reasons(tmp_path):
    p = SimpleNamespace(anonymous=False, entries=[], cited=[], blocks=[], refs_start=0, build=tmp_path, stem="main")
    assert check_report.record(p, "pdf_author", "submission", 0)["status"] == "skipped"
    assert check_report.record(p, "no_year", "bibliography", 0)["status"] == "skipped"
    p.cited = ["missing"]
    assert check_report.record(p, "no_year", "bibliography", 0)["status"] == "unavailable"
    assert check_report.record(p, "overfull", "typesetting", 0)["status"] == "unavailable"
    assert check_report.record(p, "short_last_line", "typesetting", 0)["status"] == "unavailable"
    assert check_report.record(p, "float_far", "references", 0, table=False)["status"] == "unavailable"


def test_online_partial_coverage_is_explicit():
    p = SimpleNamespace(entries=[{"key": "a", "preprint": True}, {"key": "b", "preprint": True}],
                        result=lambda s, k: {"found": False} if k == "a" else None)
    r = check_report.record(p, "no_record", "bibliography", 1)
    assert r["status"] == "partial" and "1 of 2" in r["detail"]
    p.result = lambda s, k: {"found": False}
    assert check_report.record(p, "no_record", "bibliography", 2)["status"] == "done"


def test_lookup_failures_survive_entry_refresh_without_becoming_no_record(tmp_path):
    (tmp_path / "r1").mkdir()
    refs.keep(tmp_path, 1, [{"key": "a"}])
    attempts = {"a": {"status": "unavailable", "at": "2026-11-03T10:00:00Z"}}
    assert refs.store(tmp_path, 1, "google_scholar", {}, attempts) == 0
    refs.keep(tmp_path, 1, [{"key": "a", "title": "Synthetic queues"}])
    assert refs.load(tmp_path, 1)["attempts"]["google_scholar"] == attempts
    assert refs.results(tmp_path, 1) == {"google_scholar": {}}
    done = {"a": {"status": "not_found", "at": "2026-11-03T10:01:00Z"}}
    refs.store(tmp_path, 1, "google_scholar", {"a": {"found": False}}, done)
    assert refs.load(tmp_path, 1)["attempts"]["google_scholar"] == done


@pytest.mark.parametrize("attempts", [[], {"a": None}, {"a": {"status": [], "at": "x"}},
    {"a": {"status": "unavailable", "at": "bad"}}, {"a": {"status": "unavailable", "at": "2026-11-03"}},
    {"a": {"status": "matched", "at": "2026-11-03T10:00:00Z"}},
    {"unknown": {"status": "stopped", "at": "2026-11-03T10:00:00Z"}},
    {"a": {"status": "unavailable", "at": "2026-11-03T10:00:00Z", "extra": "private"}}])
def test_invalid_lookup_records_are_refused_atomically(tmp_path, attempts):
    (tmp_path / "r1").mkdir()
    refs.keep(tmp_path, 1, [{"key": "a"}])
    before = refs.path(tmp_path, 1).read_bytes()
    with pytest.raises(EngineError):
        refs.store(tmp_path, 1, "google_scholar", {}, attempts)
    assert refs.path(tmp_path, 1).read_bytes() == before
