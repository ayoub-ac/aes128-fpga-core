# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
"""Render timing plots from the VCDs that tb/tb_waves.sv writes.

usage: plot_waves.py VCD_DIR OUT_DIR

For every scenario it draws the whole run and zoomed windows around the
events that matter: each accepted block and its valid_o (with the measured
latency in clock cycles), output back-pressure, and the pipelined key change.
Requires matplotlib and vcdvcd.
"""
import bisect
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from vcdvcd import VCDVCD  # noqa: E402

SIGNALS = ["rst_ni", "valid_i", "ready_o", "encrypt_i", "key_i", "data_i", "dbg_state", "valid_o", "ready_i", "data_o"]
CORE_STATES = {0: "IDLE", 1: "EXPAND", 2: "RUN", 3: "DONE"}
TITLES = {
    0: "aes_core: new key (expansion), same key (no expansion), output held by ready_i, decryption",
    1: "aes_core: reset in the middle of an encryption, then a new block",
    2: "aes_core_pipelined: 6 blocks with one key, then 4 with a new key (drain + expansion)",
}


class Trace:
    def __init__(self, path):
        vcd = VCDVCD(str(path))
        self.sig = {}
        for name in vcd.references_to_ids:
            short = name.split(".")[-1].split("[")[0]
            if name.count(".") == 1 and short in SIGNALS + ["clk"]:
                self.sig[short] = vcd[name].tv
        clk = self.sig["clk"]
        self.edges = [t for t, v in clk if v == "1"]
        self.period = self.edges[1] - self.edges[0]

    def value(self, name, t):
        tv = self.sig[name]
        i = bisect.bisect_right([x for x, _ in tv], t) - 1
        return tv[i][1] if i >= 0 else "x"

    def bit(self, name, t):
        return self.value(name, t) == "1"

    def before(self, name, edge):
        return self.value(name, self.edges[edge] - 1)

    def cycle(self, t):
        return (t - self.edges[0]) / self.period


def as_int(v):
    try:
        return int(v, 2)
    except ValueError:
        return None


def events(tr, scen):
    """Accepted blocks (edge index), outputs (edge index) and latencies."""
    acc, out = [], []
    for e in range(len(tr.edges)):
        if tr.before("valid_i", e) == "1" and tr.before("ready_o", e) == "1":
            acc.append(e)
        if tr.before("valid_o", e) == "1" and tr.before("ready_i", e) == "1":
            out.append(e)
    lat = []
    if scen != 2:
        for a in acc:
            # first edge after acceptance at which valid_o is high
            v = next((e for e in range(a + 1, len(tr.edges)) if tr.before("valid_o", e) == "1"), None)
            reset = any(tr.before("rst_ni", e) == "0" for e in range(a + 1, v if v is not None else len(tr.edges)))
            if v is not None and not reset:
                lat.append((a, v, v - a))
    return acc, out, lat


def draw(tr, scen, c0, c1, title, png):
    rows = [s for s in SIGNALS if s in tr.sig]
    fig, ax = plt.subplots(figsize=(14, 0.55 * len(rows) + 1.6))
    ax.set_xlim(c0, c1)
    ax.set_ylim(-0.6, len(rows) + 0.2)
    ax.set_yticks([len(rows) - 1 - i + 0.35 for i in range(len(rows))])
    ax.set_yticklabels(rows, fontsize=9, family="monospace")
    for e in tr.edges:
        c = tr.cycle(e)
        if c0 <= c <= c1:
            ax.axvline(c, color="#dddddd", lw=0.6, zorder=0)
    t_end = tr.edges[0] + c1 * tr.period
    for i, name in enumerate(rows):
        y = len(rows) - 1 - i
        tv = [(t, v) for t, v in tr.sig[name]] + [(t_end + tr.period, None)]
        for (t, v), (tn, _) in zip(tv, tv[1:]):
            x0, x1 = max(tr.cycle(t), c0), min(tr.cycle(tn), c1)
            if x1 <= c0 or x0 >= c1:
                continue
            if len(v) == 1 and name != "dbg_state":
                lvl = y + (0.7 if v == "1" else 0.0)
                ax.plot([x0, x1], [lvl, lvl], color="#c0392b" if v not in "01" else "#1f4e79", lw=1.4)
                ax.plot([x0, x0], [y, y + 0.7], color="#1f4e79", lw=0.5)
            else:
                n = as_int(v)
                if name == "dbg_state":
                    label = CORE_STATES.get(n, str(n)) if scen != 2 else f"{n:04b}" if n is not None else v
                else:
                    label = f"{n:032x}"[:8] + ".." if n is not None else "x"
                ax.fill_between([x0 + 0.05, x1 - 0.05], y, y + 0.7, color="#eaf1f8", edgecolor="#1f4e79", lw=0.8)
                if x1 - x0 > 0.9:
                    ax.text((x0 + x1) / 2, y + 0.35, label, ha="center", va="center", fontsize=7 if x1 - x0 > 2 else 5.5, family="monospace")
    acc, out, lat = events(tr, scen)
    for a in acc:
        if c0 <= tr.cycle(tr.edges[a]) <= c1:
            ax.axvline(tr.cycle(tr.edges[a]), color="#27ae60", lw=1.2, ls="--")
    for o in out:
        if c0 <= tr.cycle(tr.edges[o]) <= c1:
            ax.axvline(tr.cycle(tr.edges[o]), color="#8e44ad", lw=1.2, ls=":")
    for a, v, n in lat:
        xa, xv = tr.cycle(tr.edges[a]), tr.cycle(tr.edges[v - 1])
        if c0 <= xa and xv <= c1:
            ax.annotate("", xy=(xv, -0.35), xytext=(xa, -0.35), arrowprops=dict(arrowstyle="<->", color="#27ae60"))
            ax.text((xa + xv) / 2, -0.3, f"valid_o {n - 1} cycles after the accepting edge", ha="center", va="bottom", fontsize=8,
                    color="#1e8449")
    ax.set_xlabel("clock cycle (rising edges)   green dashed: block accepted   purple dotted: output consumed")
    ax.set_title(title, fontsize=10)
    fig.tight_layout()
    fig.savefig(png, dpi=110)
    plt.close(fig)
    return png


def windows(tr, scen):
    acc, out, lat = events(tr, scen)
    last = tr.cycle(tr.edges[-1])
    wins = [("full", 0, last)]
    cyc = lambda e: tr.cycle(tr.edges[e])  # noqa: E731
    if scen == 0 and len(lat) >= 2:
        wins.append(("zoom_new_key", cyc(lat[0][0]) - 2, cyc(lat[0][1]) + 3))
        wins.append(("zoom_same_key_backpressure", cyc(lat[1][0]) - 2, cyc(out[1]) + 3))
    if scen == 2 and acc:
        first_new = next((a for a in acc if tr.before("key_i", a) != tr.before("key_i", acc[0])), None)
        if first_new is not None:
            wins.append(("zoom_key_change", cyc(acc[5]) - 2, cyc(first_new) + 4))
    return wins


def main():
    vcd_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    for scen in (0, 1, 2):
        path = vcd_dir / f"scen{scen}.vcd"
        if not path.exists():
            continue
        tr = Trace(path)
        _, _, lat = events(tr, scen)
        if lat:
            print(f"scen{scen}: valid_o this many cycles after the accepting edge: {[n - 1 for _, _, n in lat]}")
        for tag, c0, c1 in windows(tr, scen):
            print(draw(tr, scen, c0, c1, f"{TITLES[scen]} [{tag}]", out_dir / f"scen{scen}_{tag}.png"))


if __name__ == "__main__":
    main()
