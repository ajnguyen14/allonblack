#!/usr/bin/env python3
"""Independent reference implementation (standard library only, exact fractions).

Used to cross-check the Swift HMMCore numbers. Uses Python's Fraction type, so the
forward recursion is computed EXACTLY (no floating-point error) and printed at the end.

    python3 reference/hmm_reference.py            # demo sequence 2 6 6 1 6 6
    python3 reference/hmm_reference.py 6 6 0 1    # 0 = missed roll
"""
import sys
from fractions import Fraction as Fr

PI = [Fr(4, 5), Fr(1, 5)]                                # P(S1 = F), P(S1 = L)
A = [[Fr(95, 100), Fr(5, 100)], [Fr(10, 100), Fr(90, 100)]]
E = [[Fr(1, 6)] * 6, [Fr(1, 10)] * 5 + [Fr(1, 2)]]
PAYOUT = 4
SMALL, BIG = Fr(35, 100), Fr(65, 100)


def emit(state, roll):
    return Fr(1) if roll is None else E[state][roll - 1]


def run(rolls):
    pred = PI[:]                   # P(S_t | x_1..t-1)
    rows = []
    for t, x in enumerate(rolls, 1):
        joint = [pred[i] * emit(i, x) for i in range(2)]
        c = sum(joint)
        filt = [j / c for j in joint]                                    # P(S_t | x_1..t)
        pred = [sum(filt[i] * A[i][j] for i in range(2)) for j in range(2)]  # P(S_t+1 | x_1..t)
        p6 = pred[0] * E[0][5] + pred[1] * E[1][5]
        ev = (PAYOUT + 1) * p6 - 1
        if ev <= 0 or pred[1] < SMALL:
            action = "HOLD"
        elif pred[1] < BIG:
            action = "SMALL"
        else:
            action = "BIG"
        rows.append((t, x, filt[1], pred[1], p6, ev, action))
    return rows


def main():
    args = sys.argv[1:]
    if args and args[0] == "--csv":
        rolls = [None if a == "0" else int(a) for a in args[1:]] or [2, 6, 6, 1, 6, 6]
        for t, x, cur, nxt, p6, ev, act in run(rolls):
            print(f"{t},{float(cur):.9f},{float(nxt):.9f},{float(p6):.9f},{float(ev):+.9f},{act}")
        return
    rolls = [None if a == "0" else int(a) for a in args] if args else [2, 6, 6, 1, 6, 6]
    print(" t roll  P(cur L)     P(next L)    P(next=6)    EV          action")
    for t, x, cur, nxt, p6, ev, act in run(rolls):
        print(f"{t:2d}  {'?' if x is None else x}   {float(cur):.9f}  {float(nxt):.9f}  "
              f"{float(p6):.9f}  {float(ev):+.9f}  {act}")


if __name__ == "__main__":
    main()
