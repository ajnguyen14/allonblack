# Five anticipated questions

### 1. Why bet on P(next die loaded) rather than the posterior P(current die loaded)?
The bet is on roll t+1, whose hidden state is S_{t+1}, not S_t. The posterior fₜ = P(Sₜ | x₁..ₜ) has to be pushed through the transition matrix: P(S_{t+1}=L | x₁..ₜ) = 0.90·fₜ(L) + 0.05·(1 − fₜ(L)). The result is pulled toward the stationary 1/3 because the die can switch. After 2, 6, 6, 1, 6 the posterior is 70.1% but the prediction is 64.6%. Using the posterior would have signalled BIG and overstated the edge. The outcome distribution is then P(x_{t+1}=6) = 1/6 + P(S_{t+1}=L)/3, and EV is computed from that.

### 2. Why forward filtering and not Viterbi or forward–backward for the live decision?
Viterbi maximizes the joint path probability given **all** observations, and forward–backward smoothing also conditions on future rolls. Neither quantity exists when the bet has to be placed. Forward filtering is the exact Bayesian posterior given only the past, and it updates in O(K²) per roll with no need to store or reprocess history. Viterbi also answers a different question (the single best joint path rather than per-time marginals). The app shows Viterbi as a hindsight row: the demo's Viterbi path is LLLLLL, even though the filter said roll 1 was only 13% likely loaded.

### 3. How do you prevent numerical underflow, and how do you know the math is right?
Unscaled α values shrink geometrically: after 5,000 rolls they're far below the smallest double. We normalize after every step (the scaled forward algorithm) and keep log P(x) = Σ log cₜ separately. Verification:
- comparison against brute-force enumeration of all 2^T paths on the demo and 300 random sequences, including missing data (agreement to 10⁻¹⁰)
- an independent Python implementation using exact rational arithmetic (identical to 9 decimals)
- algebraic identities: Σ P(next) = 1, P(6) = 1/6 + P(L)/3, and pₜ₊₁ = fₜA
- a 200,000-roll stress test

### 4. Your EV rule says "hold if EV is negative." Does that ever happen?
Not under these parameters. EV > 0 ⇔ P(6) > 0.2 ⇔ P(next L) > 0.1. The smallest reachable P(next L) is the fixed point of an endless run of non-sixes: 0.4q² − 0.51q + 0.05 = 0, so q ≈ 0.107 and EV ≥ +0.012. The 4:1 payout is slightly generous even for a fair-looking table, because a loaded die is always possible in the next roll. The 35% and 65% thresholds therefore act as a risk and signal-to-noise filter. The principled alternative is to maximize expected log wealth (Kelly: f\* = EV/b), scaled to ¼ Kelly to allow for parameter error. It's implemented as a setting.

### 5. What happens when the model is wrong, or the speech recognizer is wrong?
- **Model misspecification.** If the real dealer uses different switching rates or a less-biased die, predictions become miscalibrated and the EV estimates are inflated. Fixes: estimate parameters with Baum–Welch on accumulated rolls (with a prior to avoid overfitting short sessions), monitor calibration online (predicted vs observed six rate), and keep fractional stakes. The simulator results are a best case because the dealer follows the model exactly.
- **Recognition errors.** A wrong observation is worse than a missing one. A false "6" multiplies the odds of "loaded" by 3 (0.5 ÷ 1/6), when the true non-six would have multiplied them by 0.6: a 5× swing from one error. So the parser is conservative. It rejects low confidence, more than one number, out-of-range numbers and homophones that aren't spoken alone. Rejected rolls can be re-spoken, tapped or marked *Missed*, which correctly marginalizes the face rather than guessing. A principled extension is to treat recognition as a noisy channel, P(heard | true face), and fold that confusion matrix into the emission probabilities.
