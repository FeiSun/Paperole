"""Command line (CONTRACT.md §7): prints the result as JSON, errors and progress go to stderr."""
import argparse
import json
import os
import sys

from . import EngineError, api, archive, comments, project


def _rects(value):
    try:
        rects = [[float(v) for v in part.split(",")] for part in value.split(";") if part.strip()]
    except ValueError:
        rects = []
    if not rects or any(len(r) != 4 for r in rects):
        raise argparse.ArgumentTypeError("rects are x0,y0,x1,y1 separated by ';'")
    return rects


def _ids(value):
    return [t for t in (part.strip() for part in value.split(",")) if t]


def _name(value):
    tid, eq, name = value.partition("=")
    if not eq or not tid.strip() or not name.strip():
        raise argparse.ArgumentTypeError("a tag's name is ID=NAME")
    return tid.strip(), name


def _json_file(value):
    """A JSON file's contents (ref-results' results)."""
    try:
        with open(value, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise argparse.ArgumentTypeError("cannot read {} as JSON: {}".format(value, e))


def _key_page(value):
    try:
        rnd, page = (int(v) for v in value.split(":"))
    except ValueError:
        raise argparse.ArgumentTypeError("a key page is ROUND:PAGE (the page 0-based)")
    return {"round": rnd, "page": page}


def _cleared(parse):
    """An option whose value "none" sends null (clears it)."""
    return lambda value: None if value == "none" else parse(value)


def _buckets(value):
    try:
        return json.loads(value)
    except ValueError:
        raise argparse.ArgumentTypeError("buckets are JSON: {\"section key\": \"method\", …}")


def _parser():
    parser = argparse.ArgumentParser(prog="paperole", description="Paperole engine.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new", help="start a paper folder")
    p.add_argument("paper")
    p.add_argument("--title", required=True)
    p.add_argument("--student", required=True)
    p = sub.add_parser("ingest", help="snapshot, compile and compare a new round")
    p.add_argument("paper")
    p.add_argument("source", help="the student's source folder or .zip")
    p.add_argument("--main")
    p.add_argument("--engine", choices=sorted(project.ENGINES))
    p.add_argument("--shell-escape", action=argparse.BooleanOptionalAction,
                   help="build with shell escape (minted …) or without, and remember it for the paper")
    p = sub.add_parser("comment", help="write a comment on a PDF selection")
    p.add_argument("paper")
    p.add_argument("--page", type=int, required=True, help="0-based")
    p.add_argument("--rects", type=_rects, required=True, help="x0,y0,x1,y1;… in points, top-left origin")
    p.add_argument("--text", default="")
    p.add_argument("--note", default="")
    p.add_argument("--kind", choices=comments.KINDS, default="highlight")
    p.add_argument("--color", choices=sorted(comments.PALETTE), default="yellow")
    p.add_argument("--tags", type=_ids, default=[], help="tag ids, comma-separated")
    p.add_argument("--accepted", type=_ids, default=[], help="those of the tags that were suggestions taken")
    p.add_argument("--name", type=_name, action="append", default=[], help="a tag's name, ID=NAME (the advisor's own)")
    p = sub.add_parser("tag", help="set a comment's tags (any round): its whole list")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("tags", nargs="*", help="tag ids (none: no tags)")
    p.add_argument("--clear", action="store_true", help="take every tag off")
    p.add_argument("--accepted", type=_ids, default=[], help="those of the tags that were suggestions taken")
    p.add_argument("--name", type=_name, action="append", default=[], help="a tag's name, ID=NAME (the advisor's own)")
    p.add_argument("--no-state", action="store_true", help="print only the comment's id and tags")
    p = sub.add_parser("retag", help="merge one tag into another in every comment of the paper (any round)")
    p.add_argument("paper")
    p.add_argument("source", metavar="from", help="the tag id taken off")
    p.add_argument("into", nargs="?", default=None, help="the tag id put in its place (none: only taken off)")
    p.add_argument("--name", type=_name, action="append", default=[], help="a tag's name, ID=NAME (the advisor's own)")
    p.add_argument("--no-state", action="store_true", help="print only the ids of the comments changed")
    p = sub.add_parser("revive", help="reopen a comment closed in an earlier round: back into the open round, to check")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("--undo", action="store_true", help="take a comment reopened in this round out of it again")
    p = sub.add_parser("edit", help="change the note, kind or colour of a comment")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("--note")
    p.add_argument("--kind", choices=comments.KINDS)
    p.add_argument("--color", choices=sorted(comments.PALETTE))
    p = sub.add_parser("reanchor", help="place a comment of this round anew")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("--page", type=int, required=True, help="0-based")
    p.add_argument("--rects", type=_rects, required=True, help="x0,y0,x1,y1;… in points, top-left origin")
    p.add_argument("--text", default="")
    p.add_argument("--kind", choices=comments.KINDS)
    p = sub.add_parser("delete", help="delete a comment from this round")
    p.add_argument("paper")
    p.add_argument("id")
    p = sub.add_parser("verdict", help="give a verdict to a comment from an earlier round")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("verdict", choices=["verified", "reopened", "wontfix", "clear"])
    p.add_argument("-m", "--message", default="")
    p = sub.add_parser("check", help="mark a change of this round as checked")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("--clear", action="store_true", help="mark it as not checked")
    p = sub.add_parser("import", help="import the comments of an annotated build PDF")
    p.add_argument("paper")
    p.add_argument("pdf")
    p = sub.add_parser("finish", help="write final.pdf and email.txt and close the round")
    p.add_argument("paper")
    p.add_argument("--checks", action="store_true", help="send the round's check items too (the app's Checks setting)")
    sub.add_parser("resume-round", help="open the latest round again after it was finished (its earlier files are "
                                        "kept in rN/earlier)").add_argument("paper")
    p = sub.add_parser("state", help="print the state JSON")
    p.add_argument("paper")
    p.add_argument("--round", type=int, help="an earlier round, as it was left")
    p = sub.add_parser("prose", help="find a round's paragraphs for reading (rN/prose.json) and print its path")
    p.add_argument("paper")
    p.add_argument("--round", type=int, help="an earlier round")
    p.add_argument("--no-state", action="store_true", help="print only the path, not the state")
    p = sub.add_parser("links", help="print a round's link table (rN/links.json): what each reference points to")
    p.add_argument("paper")
    p.add_argument("--round", type=int, help="an earlier round")
    p = sub.add_parser("checks", help="print a round's checks (rN/checks.json): references, bibliography, consistency, "
                                      "typesetting and submission")
    p.add_argument("paper")
    p.add_argument("--round", type=int, help="an earlier round")
    p = sub.add_parser("references", help="print a round's cited entries (rN/refs.json) and the look-ups' results "
                                          "stored for them")
    p.add_argument("paper")
    p.add_argument("--round", type=int, help="an earlier round")
    p = sub.add_parser("ref-results", help="store one source's look-ups for a round's cited entries (its checks are "
                                           "built again)")
    p.add_argument("paper")
    p.add_argument("round", type=int)
    p.add_argument("source", help="semantic_scholar or google_scholar")
    p.add_argument("results", type=_json_file, help="a JSON file: {key: result}")
    p = sub.add_parser("check-ok", help="mark a check OK (its key, from checks): the paper is fine there")
    p.add_argument("paper")
    p.add_argument("key")
    p.add_argument("--clear", action="store_true", help="mark it not OK")
    p = sub.add_parser("check-items", help="print a round's check items (ids A2-03): the checks that go to the "
                                           "student, synced with the open round's checks first")
    p.add_argument("paper")
    p.add_argument("--round", type=int, help="an earlier round")
    p.add_argument("--groups", type=_ids, help="the check groups asked, comma-separated (default: all five)")
    p = sub.add_parser("check-note", help="write the advisor's words on a check item carried into the open round")
    p.add_argument("paper")
    p.add_argument("id")
    p.add_argument("text", nargs="?", default="", help="the words (none: take them off)")
    p = sub.add_parser("read", help="mark paragraphs (block indices) of this round read")
    p.add_argument("paper")
    p.add_argument("blocks", type=int, nargs="+")
    p.add_argument("--clear", action="store_true", help="mark them unread")
    p = sub.add_parser("email-preview", help="print the email finish would write now")
    p.add_argument("paper")
    p.add_argument("--checks", action="store_true", help="with the round's check items, as finish --checks")
    p = sub.add_parser("summaries", help="print each paper's next step (the papers list)")
    p.add_argument("papers", nargs="+")
    p = sub.add_parser("overview", help="print the overview of papers: rounds, sections, edits, comments, students")
    p.add_argument("papers", nargs="+")
    p.add_argument("--marks", action="store_true", help="add each round's comment and change rects")
    p.add_argument("--key-page", nargs=2, action="append", default=[], metavar=("PAPER", "ROUND:PAGE"),
                   help="the page the advisor chose for a paper (0-based)")
    p.add_argument("--tag-order", type=_ids, help="the advisor's visible tags in order, comma-separated")
    p = sub.add_parser("export", help="print every comment of papers, round by round (for CSV or JSON)")
    p.add_argument("papers", nargs="+")
    p = sub.add_parser("edit-paper", help="set a paper's title, student, or its finished day, Map Headings, key page "
                                          "or shell escape")
    p.add_argument("paper")
    p.add_argument("--title")
    p.add_argument("--student")
    p.add_argument("--finished", type=_cleared(str), default=argparse.SUPPRESS,
                   help="the day marked finished, YYYY-MM-DD (none: not finished)")
    p.add_argument("--buckets", type=_cleared(_buckets), default=argparse.SUPPRESS,
                   help="Map Headings as JSON (none: no answers)")
    p.add_argument("--key-page", type=_cleared(_key_page), default=argparse.SUPPRESS,
                   help="ROUND:PAGE, the page 0-based (none: no choice)")
    p.add_argument("--shell-escape", action=argparse.BooleanOptionalAction,
                   help="build the paper's next rounds with shell escape or without")
    sub.add_parser("fork", help="give the paper a new id (a copy kept beside the original)").add_argument("paper")
    sub.add_parser("history", help="list the saved versions of the paper's ledger").add_argument("paper")
    p = sub.add_parser("put-back", help="put back a saved version of the ledger, as a new version")
    p.add_argument("paper")
    p.add_argument("version", help="a name from history")
    p = sub.add_parser("check-folder", help="print what is wrong with paper folders (read only)")
    p.add_argument("papers", nargs="+")
    p = sub.add_parser("archive-write", help="write an export file (.zip) of paper folders")
    p.add_argument("dest", help="the .zip to write")
    p.add_argument("papers", nargs="+")
    p.add_argument("--scope", choices=archive.SCOPES, default="chosen")
    p.add_argument("--kind", choices=archive.KINDS, default="export")
    p = sub.add_parser("archive-check", help="print what an export file or a folder holds, compared with paper folders")
    p.add_argument("path")
    p.add_argument("--listed", nargs="+", default=[], metavar="PAPER", help="the paper folders it is compared with")
    p = sub.add_parser("archive-unpack", help="take one paper out of an export file into a new folder")
    p.add_argument("path")
    p.add_argument("paper", help="its folder as archive-check names it")
    p.add_argument("dest", help="the folder to put it in")
    p.add_argument("--fork", action="store_true", help="give it a new id")
    p.add_argument("--copy", action="store_true", help="Keep Both: a new id and \" (copy)\" after its title")
    p = sub.add_parser("swap-in", help="put a paper folder in place of another, which moves to Replaced by Import")
    p.add_argument("incoming")
    p.add_argument("current")
    sub.add_parser("rpc", help="serve JSON lines on stdin/stdout")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    if args.cmd == "rpc":
        from . import rpc
        return rpc.main()
    if args.cmd == "summaries":
        print(json.dumps(api.summaries({"papers": [os.path.abspath(p) for p in args.papers]}, None),
                         ensure_ascii=False, indent=2))
        return 0
    if args.cmd in ("export", "check-folder"):
        try:
            result = (api.export_comments if args.cmd == "export" else api.check_)(
                {"papers": [os.path.abspath(p) for p in args.papers]}, None)
        except EngineError as e:
            print("Error: {}".format(e), file=sys.stderr)
            return 1
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if args.cmd == "overview":
        try:
            keys = {os.path.abspath(p): _key_page(v) for p, v in args.key_page}
            result = api.overview_({"papers": [os.path.abspath(p) for p in args.papers], "marks": args.marks,
                                    "key_pages": keys, "tag_order": args.tag_order}, None)
        except (EngineError, argparse.ArgumentTypeError) as e:
            print("Error: {}".format(e), file=sys.stderr)
            return 1
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if args.cmd in ("archive-write", "archive-check", "archive-unpack", "swap-in"):
        method, params = {
            "archive-write": lambda: ("archive_write", {"dest": os.path.abspath(args.dest), "scope": args.scope,
                                                        "kind": args.kind,
                                                        "papers": [{"path": os.path.abspath(p)} for p in args.papers]}),
            "archive-check": lambda: ("archive_check", {"path": os.path.abspath(args.path),
                                                        "papers": [{"path": os.path.abspath(p)} for p in args.listed]}),
            "archive-unpack": lambda: ("archive_unpack", {"path": os.path.abspath(args.path), "paper": args.paper,
                                                          "dest": os.path.abspath(args.dest), "fork": args.fork,
                                                          "copy": args.copy}),
            "swap-in": lambda: ("swap_in", {"incoming": os.path.abspath(args.incoming),
                                            "current": os.path.abspath(args.current)}),
        }[args.cmd]()
        try:
            result = api.METHODS[method](params, lambda message: print(message, file=sys.stderr, flush=True))
        except EngineError as e:
            print("Error: {}".format(e), file=sys.stderr)
            return 1
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    paper = os.path.abspath(args.paper)
    # --shell-escape or --no-shell-escape, sent only when given (the paper's choice stays as it is otherwise)
    escape = {} if getattr(args, "shell_escape", None) is None else {"shell_escape": args.shell_escape}
    method, params = {
        "new": lambda: ("new", {"title": args.title, "student": args.student}),
        "ingest": lambda: ("ingest", dict({"source": os.path.abspath(args.source), "main": args.main,
                                           "engine": args.engine}, **escape)),
        "comment": lambda: ("comment", {"page": args.page, "rects": args.rects, "text": args.text,
                                        "note": args.note, "kind": args.kind, "color": args.color, "tags": args.tags,
                                        "accepted": args.accepted, "names": dict(args.name) or None}),
        "tag": lambda: ("tag", {"id": args.id, "tags": [] if args.clear else args.tags, "accepted": args.accepted,
                                "names": dict(args.name) or None, "state": not args.no_state}),
        "retag": lambda: ("retag", {"from": args.source, "into": args.into, "names": dict(args.name) or None,
                                    "state": not args.no_state}),
        "revive": lambda: ("revive", {"id": args.id, "undo": args.undo}),
        "edit": lambda: ("edit_comment", {"id": args.id, "note": args.note, "kind": args.kind, "color": args.color}),
        "reanchor": lambda: ("reanchor", {"id": args.id, "page": args.page, "rects": args.rects, "text": args.text,
                                          "kind": args.kind}),
        "delete": lambda: ("delete_comment", {"id": args.id}),
        "verdict": lambda: ("verdict", {"id": args.id, "note": args.message,
                                        "verdict": None if args.verdict == "clear" else args.verdict}),
        "check": lambda: ("check_change", {"id": args.id, "checked": not args.clear}),
        "import": lambda: ("import", {"pdf": os.path.abspath(args.pdf)}),
        "finish": lambda: ("finish", {"checks": args.checks}),
        "resume-round": lambda: ("resume_round", {}),
        "state": lambda: ("state", {"round": args.round}),
        "prose": lambda: ("prose", {"round": args.round, "state": not args.no_state}),
        "links": lambda: ("links", {"round": args.round}),
        "checks": lambda: ("checks", {"round": args.round}),
        "references": lambda: ("references", {"round": args.round}),
        "ref-results": lambda: ("ref_results", {"round": args.round, "source": args.source, "results": args.results}),
        "check-ok": lambda: ("check_ok", {"key": args.key, "ok": not args.clear}),
        "check-items": lambda: ("check_items", {"round": args.round, "groups": args.groups}),
        "check-note": lambda: ("check_note", {"id": args.id, "text": args.text}),
        "read": lambda: ("read", {"blocks": args.blocks, "read": not args.clear}),
        "email-preview": lambda: ("email_preview", {"checks": args.checks}),
        "edit-paper": lambda: ("edit_paper", dict({"title": args.title, "student": args.student},
                                                  **{k: getattr(args, k) for k in ("finished", "buckets", "key_page")
                                                     if hasattr(args, k)}, **escape)),
        "fork": lambda: ("fork", {}),
        "history": lambda: ("history", {}),
        "put-back": lambda: ("put_back_ledger", {"version": args.version}),
    }[args.cmd]()
    params["paper"] = paper
    try:
        result = api.METHODS[method](params, lambda message: print(message, file=sys.stderr, flush=True))
    except EngineError as e:
        print("Error: {}".format(e), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
