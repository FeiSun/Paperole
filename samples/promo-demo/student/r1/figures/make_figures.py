"""Figures for "Easy Before Hard: Curriculum-Paced Distillation for Small Code Models".

Run from this folder:  python3 make_figures.py
Writes fig_curves.pdf (Figure 1) and fig_difficulty.pdf (Figure 2) as vector PDFs.
All numbers are this paper's own (synthetic demo data, fixed seed).
"""
import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

# One colour per method, the same in every figure.
COLORS = {"CPD (ours)": "#2a78d6", "KD": "#eb6834", "KD + random pacing": "#1baf7a"}
INK, MUTED, GRID = "#1f1f1f", "#5f5e5a", "#e4e3df"

PAPER_STYLE = {
    "font.family": "serif",
    "font.serif": ["STIXGeneral", "Times New Roman", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "font.size": 8.5,
    "axes.labelsize": 8.5,
    "xtick.labelsize": 7.5,
    "ytick.labelsize": 7.5,
    "legend.fontsize": 7.5,
    "axes.edgecolor": MUTED,
    "axes.labelcolor": INK,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "axes.linewidth": 0.6,
    "xtick.major.width": 0.6,
    "ytick.major.width": 0.6,
    "pdf.fonttype": 42,
}
SAVE = {"bbox_inches": "tight", "pad_inches": 0.02, "metadata": {"CreationDate": None}}


def curves():
    """Figure 1: HumanEval pass@1 of the 1.3B student during training (mean of 3 seeds, band: min-max)."""
    rng = np.random.default_rng(7)
    steps = np.arange(0, 20001, 1000)
    base = 18.0
    mean = {
        "KD": base + 13.44 * (1 - np.exp(-steps / 5000)),
        "KD + random pacing": base + 13.28 * (1 - np.exp(-steps / 5200)),
        "CPD (ours)": base + 19.24 * (1 - np.exp(-steps / 9500)),
    }
    with plt.rc_context(PAPER_STYLE):
        fig, ax = plt.subplots(figsize=(4.6, 2.35))
        ax.axvline(12000, color=MUTED, lw=0.8, ls=(0, (3, 2)), zorder=1)
        ax.text(12150, 18.6, "end of curriculum", color=MUTED, fontsize=7, va="bottom")
        for name in ("KD", "KD + random pacing", "CPD (ours)"):
            m = mean[name] + np.concatenate([[0], rng.normal(0, 0.12, len(steps) - 2), [0]])
            spread = np.concatenate([[0], 0.35 + 0.25 * rng.random(len(steps) - 1)])
            ax.fill_between(steps, m - spread, m + spread, color=COLORS[name], alpha=0.14, lw=0, zorder=2)
            ax.plot(steps, m, color=COLORS[name], lw=1.6, zorder=3, label=name)
            ax.annotate(name, (steps[-1], m[-1]), xytext=(5, {"KD": 5, "KD + random pacing": -5,
                                                              "CPD (ours)": 0}[name]),
                        textcoords="offset points", va="center", fontsize=7.5, color=INK)
        ax.set_xlim(0, 20000)
        ax.set_ylim(17, 37)
        ax.set_yticks([18, 22, 26, 30, 34])
        ax.set_xticks([0, 5000, 10000, 15000, 20000])
        ax.set_xticklabels(["0", "5k", "10k", "15k", "20k"])
        ax.set_xlabel("Training step")
        ax.set_ylabel("HumanEval pass@1 (%)")
        ax.grid(axis="y", color=GRID, lw=0.6)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        ax.legend(loc="upper left", frameon=False, handlelength=1.6)
        fig.savefig("fig_curves.pdf", **SAVE)
        plt.close(fig)


def difficulty():
    """Figure 2: HumanEval pass@1 by teacher-difficulty quartile, KD vs. CPD (1.3B student)."""
    quartiles = ["Q1\n(easiest)", "Q2", "Q3", "Q4\n(hardest)"]
    kd = [71.2, 38.5, 12.7, 2.4]
    cpd = [72.0, 41.0, 17.5, 9.1]
    # first draft: default matplotlib look
    fig, ax = plt.subplots(figsize=(6, 4))
    x = np.arange(4)
    ax.bar(x - 0.2, kd, 0.4, label="KD")
    ax.bar(x + 0.2, cpd, 0.4, label="CPD")
    ax.set_xticks(x)
    ax.set_xticklabels(quartiles, fontsize=12)
    ax.set_ylabel("pass@1", fontsize=13)
    ax.set_title("Pass@1 by difficulty quartile", fontsize=14)
    ax.grid(True)
    ax.legend(fontsize=12)
    fig.savefig("fig_difficulty.pdf", bbox_inches="tight", metadata={"CreationDate": None})
    plt.close(fig)


if __name__ == "__main__":
    curves()
    difficulty()
