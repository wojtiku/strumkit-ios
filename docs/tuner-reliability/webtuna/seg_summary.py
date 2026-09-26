#!/usr/bin/env python3
"""Segment a StrumKit replay trace and score its steadiness.

This is the StrumKit half of the measurement pair. `realfile.mjs` in this
directory does the identical computation over the GuitarTuna/WebTuna trace of
the same recording, and the two tables are meant to be read against each other.

The shared method, stated once so both halves can be checked against it:

  * update cadence is ignored. GuitarTuna is fed 4096-sample chunks (85.3 ms at
    48 kHz); StrumKit is fed 1024-sample hops (21.3 ms at 48 kHz). Only
    per-segment statistics are compared, never per-call counts.
  * a frame is HEARD if the engine says it heard something. WebTuna:
    `CanHearANote && MeasuredPitchHz > 0`. StrumKit: `hz > 0 && state != "none"`.
  * segments are maximal runs of heard frames where the gap to the previous
    heard frame is at most 0.4 s. A longer gap opens a new segment.
  * steadiness is the p5-p95 spread of cents. Under 10 cents is steady, under 25
    is moderate, anything more is jittery.
  * a segment that changes string mid-segment is flagged, the analogue of
    WebTuna's `MIXED-STR`.

Two deliberate differences from `realfile.mjs`, both because the inputs differ:

  1. Target reference. `realfile.mjs` uses the *first* string the segment
     reported, falling back to the segment mean when that index is invalid
     (which is why its segment 5 prints NaN). Here the reference is the
     *modal* target frequency of the segment, i.e. the target the segment
     mostly held, and the number of distinct targets in the segment is printed
     instead of a NaN. A segment that changed string is a different measurement,
     not a steadier or less steady one, so it is counted, not hidden.
  2. StrumKit's `hz` is the *displayed* frequency (`reading.frequency`), because
     a held reading repeats the last fresh value and the user complaint is
     about what the needle did. `realfile.mjs` has no such distinction: every
     WebTuna call is a fresh measurement. To keep the comparison honest this
     script also reports the same statistics over the per-frame DSP estimate
     (`raw=`), which is the comparable quantity, split three ways:

       disp  every heard frame            -> what the player sees
       yin   rec=0 and raw>0              -> pure YIN, nothing substituted
       rec   rec=1                        -> the spectral recovery path's own
                                             substituted estimate

     The split matters: `raw=` is `snapshot.pitchResult.frequency`, which the
     recovery path may already have overwritten, so `raw` on its own is *not*
     the estimator. A segment where `yin` is narrow but `disp` is wide is a
     display/tracking problem; a segment where `yin` is wide too is an
     estimator problem.

Usage: python3 seg_summary.py /tmp/strumkit-real.txt [--json out.json]
"""

import json
import math
import sys

GAP_SECONDS = 0.4
STEADY_CENTS = 10.0
MODERATE_CENTS = 25.0

# displayState -> what the player is being shown
STATES = ("none", "fresh", "held", "recovered")


def parse(line):
    """Parse one `SEG|` line into a dict. Returns None for other lines."""
    if not line.startswith("SEG|"):
        return None
    parts = line.rstrip("\n").split("|")
    row = {"cfg": parts[1]}
    for token in parts[2:]:
        key, _, value = token.partition("=")
        row[key] = value
    for key in ("t", "hz", "cents", "conf", "raw", "tf", "dcents", "rms"):
        try:
            row[key] = float(row[key])
        except (KeyError, ValueError):
            row[key] = float("nan")
    for key in ("tgt", "rec"):
        try:
            row[key] = int(row[key])
        except (KeyError, ValueError):
            row[key] = -9
    return row


def count_display_transitions(states):
    """`AudioTestHelpers.countDisplayTransitions`, reproduced exactly.

    Counts every frame whose state differs from the previous one, treating the
    empty prefix as a state, then subtracts the first frame's appearance: the
    floor is 1, not 0.
    """
    transitions = 0
    previous = None
    for state in states:
        if state != previous:
            transitions += 1
        previous = state
    return max(0, transitions - 1)


def percentile(sorted_values, q):
    if not sorted_values:
        return float("nan")
    index = min(len(sorted_values) - 1, max(0, round(q * (len(sorted_values) - 1))))
    return sorted_values[index]


def spread_cents(values_hz, reference_hz):
    """p5-p95 cents spread of `values_hz` against a single reference."""
    if not values_hz or not reference_hz or reference_hz <= 0:
        return float("nan")
    cents = sorted(1200.0 * math.log2(hz / reference_hz) for hz in values_hz if hz > 0)
    return percentile(cents, 0.95) - percentile(cents, 0.05)


def mean_sd(values):
    if not values:
        return float("nan"), float("nan")
    mean = sum(values) / len(values)
    if len(values) < 2:
        return mean, 0.0
    var = sum((v - mean) ** 2 for v in values) / len(values)
    return mean, math.sqrt(var)


def modal_target_frequency(frames):
    counts = {}
    for f in frames:
        if f["tf"] > 0:
            counts[f["tf"]] = counts.get(f["tf"], 0) + 1
    if not counts:
        return float("nan")
    # Ties broken by the higher frequency, so the choice is deterministic.
    return max(sorted(counts), key=lambda tf: counts[tf])


def segment(frames, cfg):
    """Split one configuration's frames into segments of heard frames."""
    heard = [f for f in frames if f["hz"] > 0 and f["state"] != "none"]

    segments = []
    current = None
    for f in heard:
        if current is None or f["t"] - current["last_t"] > GAP_SECONDS:
            current = {"t0": f["t"], "last_t": f["t"], "frames": []}
            segments.append(current)
        current["last_t"] = f["t"]
        current["frames"].append(f)

    out = []
    for index, seg in enumerate(segments):
        frames_in = seg["frames"]
        hz = [f["hz"] for f in frames_in]
        # Pure YIN: frames the recovery path did not substitute for.
        yin = [f["raw"] for f in frames_in if f["rec"] == 0 and f["raw"] > 0]
        # What the recovery path put in the pitch result instead.
        rec = [f["raw"] for f in frames_in if f["rec"] == 1 and f["raw"] > 0]
        reference = modal_target_frequency(frames_in)

        # Frequency counted only over frames whose own target is the modal one, so
        # a target switch does not leak into a "spread".
        modal_hz = [f["hz"] for f in frames_in if f["tf"] == reference]
        modal_yin = [f["raw"] for f in frames_in
                     if f["tf"] == reference and f["rec"] == 0 and f["raw"] > 0]
        modal_rec = [f["raw"] for f in frames_in
                     if f["tf"] == reference and f["rec"] == 1 and f["raw"] > 0]

        distinct_targets = sorted({f["tf"] for f in frames_in if f["tf"] > 0})
        distinct_indices = sorted({f["tgt"] for f in frames_in})
        target_changes = max(0, len(distinct_indices) - 1)

        mean_hz, sd_hz = mean_sd(hz)
        mean_yin, sd_yin = mean_sd(yin)

        cents = spread_cents(modal_hz, reference)
        yin_cents = spread_cents(modal_yin, reference)
        rec_cents = spread_cents(modal_rec, reference)

        if not math.isnan(cents) and cents < STEADY_CENTS:
            verdict = "steady"
        elif not math.isnan(cents) and cents < MODERATE_CENTS:
            verdict = "moderate"
        else:
            verdict = "JITTERY"

        histogram = {}
        for f in frames_in:
            histogram[f["state"]] = histogram.get(f["state"], 0) + 1

        out.append({
            "cfg": cfg,
            "seg": index,
            "t0": seg["t0"],
            "dur": seg["last_t"] - seg["t0"] + 0.0213,  # one hop, as realfile.mjs adds one chunk
            "note": frames_in[0]["note"],
            "target": reference,
            "n": len(frames_in),
            "hz_mean": mean_hz,
            "hz_sd": sd_hz,
            "cents_spread": cents,
            "verdict": verdict,
            "yin_n": len(yin),
            "yin_mean": mean_yin,
            "yin_sd": sd_yin,
            "yin_cents_spread": yin_cents,
            "rec_n": len(rec),
            "rec_cents_spread": rec_cents,
            "recovered_n": histogram.get("recovered", 0),
            "held_n": histogram.get("held", 0),
            "fresh_n": histogram.get("fresh", 0),
            "target_changes": target_changes,
            "distinct_targets": len(distinct_targets),
            "rms_max": max(f["rms"] for f in frames_in),
        })
    return out


def fmt(value, width=8, places=2):
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "-".rjust(width)
    return f"{value:{width}.{places}f}"


def report(frames_by_cfg, as_json=False):
    results = []
    for cfg in sorted(frames_by_cfg):
        frames = frames_by_cfg[cfg]
        heard = [f for f in frames if f["hz"] > 0 and f["state"] != "none"]
        histogram = {s: sum(1 for f in frames if f["state"] == s) for s in STATES}
        segments = segment(frames, cfg)
        results.append({
            "cfg": cfg,
            "frames": len(frames),
            "heard": len(heard),
            "heard_pct": 100.0 * len(heard) / len(frames) if frames else float("nan"),
            "transitions": count_display_transitions([f["state"] for f in frames]),
            "histogram": histogram,
            "segments": segments,
        })

    for result in results:
        print(f"\n=== cfg={result['cfg']} ===")
        print(f"  frames={result['frames']}  heard={result['heard']} "
              f"({result['heard_pct']:.0f}%)  displayTransitions={result['transitions']}")
        print("  states: " + "  ".join(f"{s}={result['histogram'][s]}" for s in STATES))
        print("  seg    t0(s)  dur(s)  note   tfreq      n   Hz mean     sd  "
              "cents  verdict  | YIN n   sd  cents | REC n  cents | tgt#  "
              "rec held fresh  rmsMax")

        for s in result["segments"]:
            flags = []
            if s["target_changes"] > 0:
                flags.append(f"MIXED-TGT({s['target_changes']})")
            line = (f"  {s['seg']:>3} {fmt(s['t0'], 7, 3)} {fmt(s['dur'], 6, 2)} "
                    f"{s['note']:<5} {fmt(s['target'], 8, 1)} {s['n']:>4} "
                    f"{fmt(s['hz_mean'])} {fmt(s['hz_sd'], 7, 3)} "
                    f"{fmt(s['cents_spread'], 6, 1)}  {s['verdict']:<8} | "
                    f"{s['yin_n']:>4} {fmt(s['yin_sd'], 6, 2)} {fmt(s['yin_cents_spread'], 6, 1)} | "
                    f"{s['rec_n']:>4} {fmt(s['rec_cents_spread'], 6, 1)} | "
                    f"{s['target_changes']:>4}  "
                    f"{s['recovered_n']:>4} {s['held_n']:>5} "
                    f"{s['fresh_n']:>5}  {fmt(s['rms_max'], 7, 5)}")
            if flags:
                line += "  " + " ".join(flags)
            print(line)

        verdicts = {}
        for s in result["segments"]:
            verdicts[s["verdict"]] = verdicts.get(s["verdict"], 0) + 1
        summary = "  ".join(f"{k}={v}" for k, v in
                            sorted(verdicts.items(), key=lambda kv: -kv[1]))
        print(f"  {len(result['segments'])} segments, {result['heard']} heard frames, "
              f"mixed-target segments={sum(1 for s in result['segments'] if s['target_changes'] > 0)}")
        if summary:
            print(f"  verdicts: {summary}")

        jittery = [s for s in result["segments"] if s["verdict"] == "JITTERY"]
        if jittery:
            worst = max(jittery,
                        key=lambda s: s["cents_spread"] if not math.isnan(s["cents_spread"]) else -1)
            print(f"  most jittery: seg {worst['seg']} t0={worst['t0']:.3f}s "
                  f"{worst['note']} displaySpread={fmt(worst['cents_spread'], 6, 1)}c "
                  f"yinSpread={fmt(worst['yin_cents_spread'], 6, 1)}c "
                  f"hz_sd={fmt(worst['hz_sd'], 7, 3)}")

    if as_json:
        return results
    return None


def main(argv):
    path = argv[1] if len(argv) > 1 else "/tmp/strumkit-real.txt"
    json_out = None
    if "--json" in argv:
        json_out = argv[argv.index("--json") + 1]

    frames_by_cfg = {}
    with open(path) as handle:
        for line in handle:
            row = parse(line)
            if row:
                frames_by_cfg.setdefault(row["cfg"], []).append(row)

    if not frames_by_cfg:
        print(f"no SEG| lines in {path}", file=sys.stderr)
        return 1

    results = report(frames_by_cfg, as_json=json_out is not None)
    if json_out:
        with open(json_out, "w") as handle:
            json.dump(results, handle, indent=2, default=str)
        print(f"wrote {json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
