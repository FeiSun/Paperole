# Fixture paper: versions and edits

The paper is a fictional English CS article, "Predictive Warm Pools for Serverless Cold-Start Reduction", by the
student "Lin Zhou". It uses the article class, 10pt, pdflatex, with no `.bib` (`thebibliography`, 10 entries).

| file | contents |
|---|---|
| `main.tex` | abstract; §1 Introduction, §2 Related Work, §4 Evaluation, §5 Conclusion; Table 1; Figure 1 |
| `sections/method.tex` | §3 Method, via `\input`; Eq. (1) `eq:ewma`, Eq. (2) `eq:cost` |
| `figures/coldstart.png` | identical in all versions |

- Each version builds with `latexmk -pdf` or pdflatex run twice, with no warnings and 4 pages.
- Lines in `.tex` files are hard-wrapped at about 80 characters.
- Page numbers below are 0-based indexes into that version's build PDF.
- Each "select" phrase occurs exactly once in its version's PDF, so a test can find it with PyMuPDF
  `page.search_for(phrase)`. The rects that returns use the contract's coordinates (top-left origin).

## v1 → v2

| id | where | v1 lines | v2 lines | edit | expected from texdiff |
|---|---|---|---|---|---|
| E1 | main.tex §1 ¶2 | 41 | 41 | word: `simple` → `static` | replace |
| E2 | main.tex §2 ¶2 | 76–77 | 77–79 | sentence rewrite (see below) | one replace after merging; "Both approaches" and the final "." stay equal |
| E3 | main.tex §4 last ¶ | 153–154 | point in 150 | deleted sentence `The memory footprint is two floating-point numbers per function.` | delete |
| E4 | main.tex §4 | 105–108 | 153–156 | paragraph `Our simulator is event-driven … share them.` moved verbatim from after the baselines ¶ to the end of §4 | one move |
| E5 | main.tex §5 | after 161 | 162–164 | new sentence `Because the controller needs no changes to the functions themselves, it can be deployed on existing platforms without involving developers.` | insert, **unrequested** |
| E6 | sections/method.tex Eq. (2) | 29 | 29 | `c_m \, k` → `c_m \tau \, k` | insert (`\tau`) |
| E7 | main.tex Table 1, Hybrid row | 121 | 118 | P99 latency `655` → `671` | replace, **unrequested** |
| E8 | main.tex §2 ¶1 | 63–70 | 63–71 | re-wrapped at ~70 characters, words unchanged | **no hunk** |
| E9 | main.tex §4 ¶1 | 98 | 100 | `% TODO: report variance over random seeds` → `% TODO: report variance over five random seeds (ask Prof. Li which ones)` | **no hunk** |

- E2 changes `Both approaches decide when to keep a single instance alive.` into `Both approaches reason about the
  lifetime of one instance and leave the number of concurrent instances to the autoscaler.`
- The rest of E3's paragraph is re-wrapped (v2 lines 150–151) but otherwise unchanged.
- The expected changes for round 2 are E1–E7: six hunks plus one move. In the contract's order (new file, then new
  offset) that is E1, E2, E7, E3, E4, E5, E6, numbered c01–c07.

## v2 → v3

| id | where | v2 lines | v3 lines | edit | expected from texdiff |
|---|---|---|---|---|---|
| F1 | main.tex §1 ¶3 (contributions) | 49–58 | 49–57 | heavy rewrite of the whole paragraph | ≥ 1 replace (2 with the 5-token merge rule) |
| F2 | main.tex §2 heading | 60 | 59 | `\section{Related Work}` → `\section{Background and Related Work}` | insert |
| F3 | sections/method.tex §3 "Safety limits" | 49 | 49 | `30 minutes` → `20 minutes` | replace, **unrequested** |

## End-to-end review scenario

### Round 1: ingest v1, write comments, finish

| comment | kind | select (v1 PDF) | page | note |
|---|---|---|---|---|
| R1-01 | highlight | `simple keep-alive policy` | 0 | simple 不准确，改成 static 或 fixed。 |
| R1-02 | highlight | `Both approaches decide when to keep a single instance alive.` | 0 | 这句不准确：Hybrid 也决定预热窗口。 |
| R1-03 | strikeout | `The memory footprint is two floating-point numbers per function.` | 2 | 多余，删掉。 |
| R1-04 | highlight | `Our simulator is event-driven` | 1 | 这段放到本节最后，作为局限讨论。 |
| R1-05 | highlight | `The expected cost of a pool of size` | 1 | 式 (2) 里 c_m 的单位和 τ 对不上。 |
| R1-06 | highlight | `boots a minimal microVM in about 125` | 0 | 125 ms 出自哪里？加引用。 |
| R1-07 | note | `which performed best on a held-out day of the trace` | 1 | 只用一天调参够吗？ |

- Every comment gets method `selection` and confidence 1.0. Its source range covers the selected words.
  - R1-05 (line 27) and R1-07 (line 20) are in `sections/method.tex`.
  - The others are in `main.tex`: R1-01 at line 41, R1-02 at 76–77, R1-03 at 153–154, R1-04 at 105, R1-06 at 66.
- At finish, the email has only "New comments (7)".

### Round 2: ingest v2

All seven comments are carried into round 2.

| comment | state | page | attached change | confidence |
|---|---|---|---|---|
| R1-01 | changed | 0 | E1 | ≥ 0.75 (about 0.99) |
| R1-02 | changed | 0 | E2 | ≥ 0.75 (about 0.91) |
| R1-03 | gone | 2 | E3 | ≥ 0.75 (about 0.87) |
| R1-04 | moved | 2 | E4 | 1.0 |
| R1-05 | changed | 1 | E6 (the equation is in the same sentence) | 1.0 |
| R1-06 | unchanged (E8 is only a re-wrap) | 0 | none | 1.0 |
| R1-07 | unchanged | 1 | none | 1.0 |

- Unrequested changes are exactly E5 and E7.
- R1-04's new rects overlap `search_for("Our simulator is event-driven")` on v2 page 2.

Verdicts:

| comment | verdict | note |
|---|---|---|
| R1-01 | verified | |
| R1-02 | reopened | 还是没说清楚和 Hybrid 的区别。 |
| R1-03 | verified | |
| R1-04 | verified | |
| R1-05 | reopened | τ 应该放进 c_m 的定义，而不是式子里。 |
| R1-06 | (none) | |
| R1-07 | wontfix | 这次先不改。 |

New comments:

| comment | kind | select (v2 PDF) | page | note |
|---|---|---|---|---|
| R2-01 | highlight | `671` | 2 | 这个数为什么变了？重跑了还是笔误？ |
| R2-02 | highlight | `A short-term forecast of the rate is therefore enough` | 0 | enough 需要论证。 |
| R2-03 | highlight | `Related Work` (the §2 heading) | 0 | 标题改成 Background and Related Work。 |

At finish:
- final.pdf has 1 summary page + 4 pages, and 10 comment annotations: 3 new comments and 7 carried ones. hyperref's
  Link annotations are also present, as they are in the build PDF.
  - R1-03 (gone) and R1-07 (note) are Text annotations.
  - The Contents start with `[R2-01]` for new comments and `[R1-02 · reopened]` style for carried ones.
- The email lists:
  - Reopened: R1-02, R1-05
  - Still open: R1-06
  - New comments: R2-01–R2-03
  - `Closed: R1-01, R1-03, R1-04 (verified); R1-07 (won't fix)`

### Round 3: ingest v3

R1-02, R1-05, R1-06, R2-01, R2-02 and R2-03 are carried into round 3. R1-01, R1-03, R1-04 and R1-07 are closed and
are not carried.

| comment | state | page | attached change |
|---|---|---|---|
| R1-02 | unchanged | 0 | none |
| R1-05 | unchanged | 1 | none |
| R1-06 | unchanged | 0 | none |
| R2-01 | unchanged | 1 (Table 1 moves to page 1 in v3) | none |
| R2-02 | changed, confidence < 0.75 (about 0.15; heavy rewrite) | 0 | the F1 hunk(s) that touch its sentence |
| R2-03 | changed | 0 | F2 |

- Unrequested changes are F3, plus any F1 hunk that does not touch R2-02's sentence.
- No change is attached to R1-02, R1-05, R1-06 or R2-01.
