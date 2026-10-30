# Promo demo paper: planted issues

Synthetic paper for the PaperCollab promo video. Everything here is made up for the demo: the paper, its numbers and the people. No content comes from any real review.

- Paper: "Easy Before Hard: Curriculum-Paced Distillation for Small Code Models". It is an anonymous ICLR 2027 submission: the PDF prints "Anonymous authors". Topic: a curriculum for distilling a 7B code model into 350M and 1.3B students.
- Student: Maya Chen (fictional).
- Sources: `student/r1` (first draft) and `student/r2` (revision). The figures are made by `figures/make_figures.py` beside them (anaconda python3, matplotlib 3.7). Only the ICLR 2027 template files were copied from the template folder.
- Review: `review/`. Round 1 is closed with 14 comments. Round 2 is open, and all 14 comments are carried over with no verdicts yet.
- Citations are real works (Hinton et al. 2015, Kingma & Ba 2015, Vaswani et al. 2017, Kim & Rush 2016, Bengio et al. 2009, Platanios et al. 2019, Chen et al. 2021, Austin et al. 2021 and others). All numbers are the paper's own.

## Planted issues and the advisor's comments (round 1)

Lines refer to `student/r1/main.tex`. Pages are those of the round-1 PDF (1-based).

| ID | Issue | Where (r1) | Kind, colour | Tag | Round 2 |
|---|---|---|---|---|---|
| R1-01 | Overclaim: "achieves state-of-the-art results for small code models" | Abstract, l.30, p.1 | highlight, yellow | logic | fixed |
| R1-02 | Abstract says +4.1 pass@1, but Table 1 gives +3.7 (31.2 to 34.9) | Abstract, l.31, p.1 | highlight, yellow | evidence | fixed, with a student note |
| R1-03 | Typo: "distilation" | §1 ¶2, l.42, p.1 | underline, pink | grammar | fixed |
| R1-04 | Citation slip: `\citet` where `\citep` is needed ("soft targets Hinton et al. (2015)") | §1 ¶2, l.43, p.1 | highlight, pink | format | fixed |
| R1-05 | Unclear sentence ("…when they come early, which then the signal it gets is mostly noise that it still fits") | §1 ¶3, l.49, p.1 | highlight, yellow | clarity | partly fixed: still awkward |
| R1-06 | Vague related-work sentence ("studied extensively … helpful in many different settings") | §2 Curriculum learning, l.79, p.2 | highlight, yellow | evidence | fixed (now names Bengio, Kumar, Platanios) |
| R1-07 | Undefined symbol: β in Eq. (2) | §3.2 Eq. (2), l.111–114, p.3 | box, blue | math | fixed in the next sentence, with a student note |
| R1-08 | Eq. (3): g(t) exceeds 1 once t > S (no clipping) | §3.3 Eq. (3), l.133–136, p.3 | box, blue | math | fixed with `\min(1, ·)` |
| R1-09 | Table 1 is too long (16 rows, ablations mixed into the main comparison) | §4.1 Table 1, l.205–234, p.4 | box, purple | figures | fixed: ablations moved to Table 3 in Appendix B, with student notes |
| R1-10 | Inconsistent notation: temperature is T in Eq. (1) and Table 1, but τ in §4.1 and Algorithm 1 | §4.1 Training, l.193, p.4 | highlight, blue | math | partly fixed: §4.1 now says T, but Algorithm 1 still uses τ |
| R1-11 | Missing baseline: sequence-level KD (Kim & Rush 2016), which §2 cites | §4.1 Baselines, l.202, p.4 | highlight, yellow | evidence | kept as is; the student's note explains why |
| R1-12 | (Praise) "on the hardest quartile, CPD solves 9.1% … against 2.4% for KD" | §5, l.263, p.5 | highlight, teal | praise | unchanged |
| R1-13 | Claim without evidence: "more robust to distribution shift" | §5, l.265, p.5 | strikeout, pink | logic | ignored (unchanged, no note) |
| R1-14 | Figure 2's style does not match Figure 1: default matplotlib look, a title inside the plot, larger font, and CPD orange here but blue in Figure 1 | §5 Figure 2, l.267–272, p.6 | box, purple | figures | fixed: new figure file in Figure 1's style |

The draft has one more realistic flaw that was left uncommented: the appendix table's `[h]` placement triggers a LaTeX float warning.

## Round 2 (`student/r2`)

Student notes (`% R1-xx` in the .tex):
- R1-02 (abstract, end of line): "3.7 is right; 4.1 came from an earlier run, sorry."
- R1-07 (§3.2, end of line): "Defined beta here; we use 0.5 everywhere."
- R1-09 (§5 and twice in Appendix B): "Moved the ablation rows to Table 3 in Appendix B."
- R1-11 (§4.1, own line): "Kept as is for now: SeqKD needs teacher samples for all 386k problems (about 6 GPU-days). I can run it before the camera-ready if you think it is needed." This is the note that explains why something was kept as is.

Edits nobody asked for (the engine flags both as unrequested):
- §4.1 Data: training set "412k" became "386k" Python problems.
- §6 Conclusion: a new sentence, "We will release our code and the difficulty scores of the training set upon publication."

R1-05's sentence is only half rewritten: "are what" became "that" and ", which then the signal it gets is" became "yield", so it still reads badly. Both edits replace words and none only deletes them. A deletion would show the app's deletion × on p.1, over the letters next to it, inside the promo's S1 and S5 views.

## Other students (for the overview), in `others/`

- Leo Park, "Retrieval-Augmented Docstring Generation for Legacy Fortran Code" (2 pages, ICLR style). Three rounds; round 3 is open.
  - Round 1 had five comments: R1-01 (evidence), R1-02 (logic), R1-03 (Eq. 1, math), R1-04 (Table 1, figures) and R1-05 (logic).
  - In round 2, R1-02, R1-03 and R1-04 were resolved, R1-01 and R1-05 were followed up, and R2-01 (clarity) was added.
  - In round 3, all three open comments are revised, and R1-05 has a student note.
- Sara Okafor, "Confidence-Gated Early Exit for On-Device Speech Recognition" (2 pages, two-column article). Round 1 is closed, so it is the student's move.
  - Comments: R1-01 (evidence), R1-02 (Table 1, figures), R1-03 (Eq. 1, math), R1-04 (strikeout, logic) and R1-05 (praise).

## Promo takes (`tools/build_reviews.py --takes DIR`)

These are fresh folders for the promo video's takes (`design/promo/STORYBOARD.md` §7), all built from `tools/reviews.json`:
- `take-A/review`: Maya Chen's round 1 is open with only R1-01 placed, so the comment made on camera becomes R1-02. Its note in `reviews.json` is the text typed on camera, "Table 1 says +3.7. Which is right?".
- `take-B/`: the three folders above, except that Leo Park's round 3 is resolved and finished. Once Maya's round 2 is finished, nothing waits on the advisor.
- `take-C/`: take B with Maya's round 2 answered as the take answers it, and both unrequested edits checked. That is 10 resolved; follow-ups on R1-05, R1-10 and R1-13; R1-11 kept as is. This is the state of the done card, right before Finish.
