# PRD — Multi-channel affective sensing: hands, eyes & gaze (beyond the face)

**Status:** Draft — **superseded by `docs/design/prd-multichannel-affect-sensing-v2.md` (2026-07-11)**, the deep-research-wave revision; this v1 remains as the original derivation. Derived from the spike `docs/design/spike-body-language-gesture.md` (read it for the full evidence base, platform constraints, and citations — this PRD is the buildable scope). **2026-07-11.**

**One-line:** Expand the app from face-only emotion to the *other* affect channels a Vision Pro can actually sense — **hands**, **eyes**, and **head pose** — each as an **independent** readout, with **optional, individually-explained** fusion modes on top. No torso/posture (physically unsensable on-device), no raw gaze/pupil (walled off), no "body-language dictionary" (pseudoscience).

---

## 1. Introduction / Overview

Today the app infers emotion from the face via the Persona camera. But the face alone misses **covert and discordant** states: a composed face over agitated hands, rising covert arousal betrayed by blink rate, disengagement shown by eye closure. These are the signals the wearer, looking at their own readings, would most want to see — and they're currently invisible.

This feature adds the channels the hardware genuinely gives us:

- **Hands** — gesture energy, openness, and self-touch → **arousal / agitation / engagement**, via ARKit hand tracking in the immersive space.
- **Eyes** — blink rate + eye-openness dynamics → **arousal / fatigue / attention**, derived from the Persona pixels the face pipeline *already processes* (the wearer's eyes move and blink in that feed); plus a **gated, best-effort avatar-iris gaze proxy**.
- **Head pose & tilt** — pitch (down+averted→shame/submission, up+expanded→pride/dominance), yaw-away (aversion), and head-motion energy (engagement/arousal) → a **dominance/approach + arousal** contribution. Head pose does **dominance & arousal** well and **valence poorly — valence stays on the face**; lateral tilt is a weak, low-confidence cue only. The Persona face's yaw/roll/pitch is **already computed** (roll-correction today); real head 6DoF comes from `WorldTrackingProvider` in the immersive space.

**Design spine (from the spike):**
1. The headset senses **hands + head + (Persona) face/eyes** — **not** torso, shoulders, arms-at-rest, stance, or legs. Posture is a **future** path (paired iPhone), not this feature.
2. Hands and eyes honestly carry **arousal / attention**, not new discrete emotions and not valence "tells." They sharpen the *dimensional* reading and can break the face's valence ties at peak intensity — they do not invent new labels.
3. **Every channel is independent and per-user-calibrated** (mirroring the existing neutral-face `NeutralBaseline`). **Fusion is optional, explained, and never default-on.**
4. **Honesty bar:** low-dimensional calibrated meters with explicit uncertainty. No gesture dictionary, no gaze-direction dictionary, no pupil, no lie detection.

---

## 2. Goals

- **G1** — Add **hands**, **eyes**, and **head pose** as independent, per-user-baselined affect channels, each viewable on its own.
- **G2** — Offer **optional fusion modes** that combine channels in scientifically sensible ways, **each with an in-app explanation** of why the combination is valid; fusion is opt-in, off by default.
- **G3** — Keep every surfaced claim **defensible** (arousal / attention / valence-tiebreak — never new emotion categories or single-cue "tells").
- **G4** — **Degrade gracefully**: any channel unavailable (hands out of frustum, immersive space closed, blink unreadable) leaves the others fully working; face-only behavior is unchanged when nothing else is on.
- **G5** — Fix the **head-pitch → false-anger** artifact (a real bug, independent of this feature).
- **G6** — Add a distinct, **orthogonal focus/effort (cognitive-load)** readout, clearly separated from emotion, off by default.
- **G7** — Let the emotion **aura** optionally reflect the body/eye arousal, not just the face.

---

## 3. Channels & the reading model

### 3.1 Four independent channels (default view)

| Channel | Source | Honest signal | Availability |
|---|---|---|---|
| **Face** (exists) | Persona camera → landmarks → 14 AUs → classifier | discrete emotion + valence/arousal | window or immersive |
| **Eyes** (new) | same Persona feed → blink + eye-openness dynamics; existing AU5/6/7 + new AU43 | **arousal / fatigue / attention** | window or immersive (no new permission) |
| **Hands** (new) | ARKit `HandTrackingProvider` → joint stream | **arousal / agitation / engagement** | **immersive space only** + hand-tracking auth |
| **Head** (new) | Persona face pose (already computed) + real head 6DoF (`WorldTrackingProvider`) | **dominance/approach + arousal/engagement** (pitch, tilt, yaw, motion) | face-pose: window or immersive; head-6DoF: immersive only |

Each publishes its **own** reading and meters and can be viewed alone. This is the "everything independent" baseline.

### 3.2 Optional fusion modes (opt-in, each explained in-app)

Fusion is a set of **toggles**, off by default. Each mode ships with a short **"why this is sensible"** explanation surfaced in the UI (the developer explicitly wanted the rationale visible, not a black box).

- **FUSE-1 · Face + Eyes → arousal-sharpened emotion.**
  *Why:* blink rate and eye-openness ride the **same feed** as the face, so this is the tightest, cheapest fusion. A neutral-ish face with a climbing blink rate reads as **higher covert arousal** than the face alone shows. The head/face-pitch anger-correction (§3.4) lives here too.
- **FUSE-2 · Face + Hands → masked-affect / congruence.**
  *Why:* hands carry arousal **independent** of the face. When facial valence is confident but the hands are agitated, surface **"composed but activated"** (the calm-face/restless-hands insight). At **peak intensity**, when the face goes valence-ambiguous, hand tension/energy **breaks the tie** (Aviezer 2012).
- **FUSE-3 · Eyes + Hands → arousal consensus.**
  *Why:* blink and gesture-energy are **two independent arousal estimators**. Agreement **raises confidence** in the arousal reading; disagreement is **flagged as ambiguous** rather than averaged away.
- **FUSE-4 · All channels → combined affect reading.**
  *Why:* face = discrete label + valence; hands + eyes = arousal/agitation; head = dominance/approach + motion arousal. Combine into one valence–arousal–(dominance)–agitation reading **with each channel's contribution shown**, so the fusion is legible, not magic.

**Rule:** fusion only ever moves the **dimensional** axes (mainly arousal) and the **valence tie-break** — it **never** creates a new discrete emotion label. Default app state = independent channels; the user opts into any fusion.

### 3.3 Orthogonal focus/effort axis (secondary, off by default)

A **cognitive-load** readout from **blink-suppression + gaze-aversion** (low blink + steady low expressivity ≈ focused internal effort). Kept **orthogonal to emotion**, mirroring the app's existing *intensity-vs-confidence* separation. Never folded into valence/arousal; shown as a separate, low-confidence "focus/effort" indicator.

### 3.4 Head/face-pitch anger correction (quick win)

Looking **down** tilts the face so the brow reads as a lowered V-shape (AU4-like) → **false "anger"** — the AU4 "imposter" (Witkower & Tracy 2019 *Psych Science*, 2020 *Emotion*). Down-pitch should **discount, not amplify**, the geometric anger score; correct AU4/anger for face pitch (already computed at `FaceGeometry.swift:235-237`). Ships independent of everything else.

### 3.5 Gated Tier-2: avatar-iris gaze proxy

The Persona re-renders the wearer's eye movement, but **fidelity at the virtual-camera framing is unknown**. Extract the currently-ignored Vision `leftPupil`/`rightPupil` landmarks; **probe on-device first** (§US-G1). Only if the iris demonstrably tracks real gaze do we ship a **coarse gaze-aversion / downward-gaze** hint — **never** a direction→meaning dictionary.

### 3.6 Head pose & tilt (Channel 4)

Two sources, one already latent:
- **Face-pose-in-image** (yaw/roll/pitch from `VNFaceObservation`, `FaceGeometry.swift:235-237`) — **already computed**, currently used only for roll-correction. Re-interpreting it as an affect signal is nearly free (window or immersive).
- **Real head 6DoF** via ARKit `WorldTrackingProvider` device anchor — immersive space only; adds head-motion **energy** and nod/shake dynamics the in-image pose can't give.

**Head pose's job is DOMINANCE/APPROACH + AROUSAL — not valence (leave valence to the face).** The two *well-supported, felt-state* displays (spontaneous, cross-cultural, present in congenitally-blind individuals ⇒ innate — Tracy & Matsumoto 2008; Tracy & Robins 2004/07):
- **Head back + expanded** → **pride / confidence / dominance** (approach, high dominance).
- **Head down + gaze/head averted** → **shame / embarrassment / submission / defeat** (low dominance, withdrawn).

Weaker, dimensional-only cues:
- **Yaw toward** → attention / approach; **yaw away** → aversion / disengagement (part of the shame cluster). *Med.*
- **Head-motion energy** (angular velocity integrated over a window) → **arousal / engagement**, a continuous scalar — parallels gesture-energy → arousal. **Nod / shake** carry reliable affective *tone*, but their propositional meaning is culture-coded (head-waggle inverts in parts of India / Bulgaria / Greece) → keep labels low-confidence.
- **Lateral tilt (roll)** — the roll you *already compute* — is the **most over-claimed** head cue: real but **sign-unstable and smile/gender-confounded** (Otta 1994; Torrance 2020). Use **low-confidence, dimensional** only; **no "tilt = curiosity" dictionary.**

Two design-critical caveats from the science:
1. **Pitch is gaze-gated and non-monotonic.** Head-**down** means *shame/submission* only when gaze is **averted**; with **direct** gaze the same down-tilt manufactures a V-shaped-brow illusion that reads **angrier / more dominant** (Witkower & Tracy **2019** *Psych Science* — the AU4 "imposter"; **2020** *Emotion* — anger intensified). So head-down is **ambiguous without gaze** — which ties this channel to the gaze tier.
2. **Guard the classifier against the AU4 imposter (§3.4):** a downward head tilt **manufactures geometric anger evidence**, so down-pitch should **discount, not amplify**, the face's anger score.

Head pose is the **best body channel for a dominance/approach axis** — a genuinely new dimension the face gives only weakly. Everything is **deviation from the user's own neutral head pose** (resting pitch has a large idiosyncratic offset and shifts with where the UI sits) — same `NeutralBaseline` pattern as the face.

---

## 4. User Stories

Small, session-sized. Verification bar for this repo: `build_sim` (Apple Vision Pro) compiles green; math covered by `EmotionSelfTests.runAll()`; behavior verified **on-device by the developer** (no simulator E2E).

### Eyes — Tier 1

**US-E1 · Blink detection**
As a user, I want the app to detect my blinks so eye behavior can inform arousal.
- [ ] A blink detector reads existing `eyeOpenLeft/Right` (`FaceGeometry.swift:189-190`) — **no `FaceGeometry` change** — and emits discrete blink events (closure below a per-user threshold, then reopen).
- [ ] Robust to the ~15 Hz throttle: tracks **events over a rolling window**, not per-blink duration (15 Hz undersamples a 100–400 ms blink).
- [ ] Added as new AUs **AU43 (closure) / AU45 (blink)** in `ActionUnit` (`ActionUnits.swift:16-31`), or as a standalone detector if cleaner; classifier prototypes + `EmotionSelfTests` extended if AUs are added.
- [ ] `build_sim` green; self-tests pass. On-device: blinks register visibly in a debug HUD.

**US-E2 · Per-user blink baseline + rate**
- [ ] Resting blinks/min learned per user (mirror `NeutralBaseline`), persisted in `UserDefaults`.
- [ ] Rolling blinks/min computed as a **delta from baseline** (absolute rate is meaningless — see spike §7.4).
- [ ] Re-runnable calibration, like the neutral-face flow.

**US-E3 · Independent EyeReading (arousal/fatigue/attention)**
- [ ] A published `EyeReading` beside `reading` (seam c, `EmotionEngine.swift:34-39`) with: blink-rate delta, eye-openness variance, prolonged-closure flag.
- [ ] Meters map to **arousal** (rate ↑) and **attention/fatigue** with **explicit ambiguity labeling** (high blink = aroused *or* disengaged — never asserted as one).
- [ ] Viewable as its own channel; unaffected by hands/immersive state.

**US-E4 · Anger/face-pitch correction**
- [ ] Anger/AU4 scoring is corrected for face pitch so a downward look no longer inflates anger.
- [ ] `EmotionSelfTests` gains a case: synthetic down-pitch + neutral brow must **not** classify anger. On-device: looking down at your lap no longer flips the reading to anger.

### Hands

**US-H1 · Hand-tracking acquisition (keystone)**
- [ ] `ARKitSession` + `HandTrackingProvider` runs while the mixed `ImmersiveView` is open; `NSHandsTrackingUsageDescription` added to Info.plist.
- [ ] A debug HUD plots per-frame mean joint speed, hand aperture, and min hand-to-head distance.
- [ ] On-device: **wave / rest / face-touch produce clearly separable traces** (the prove-or-kill gate). If not legible → stop and reassess before US-H2/H3.

**US-H2 · Hand feature extraction (off-main)**
- [ ] A `HandAnalyzer` **actor** (explicit isolation — MainActor-default gotcha) consumes the anchor stream and returns a `Sendable` result: motion energy, openness, self-touch events, gesture rate.
- [ ] Robust to frustum drop-outs (features are rate/energy over a window; hands-out-of-view ≈ low arousal, not "missing").

**US-H3 · Independent HandReading + baseline**
- [ ] Per-user **hand baseline** (resting self-touch rate, resting gesture rate/amplitude) persisted like `NeutralBaseline`.
- [ ] Published `HandReading` (arousal / agitation / engagement), each a **delta from baseline**, viewable as its own channel.

### Head pose

**US-HP1 · Surface face-pose as an affect signal (near-free)**
As a user, I want my head pitch/tilt/turn read as affect, since the pose is already computed.
- [ ] Re-use the existing `VNFaceObservation` yaw/roll/pitch (`FaceGeometry.swift:235-237`) to derive pitch (down/up), lateral tilt, and yaw-away — each as a **delta from a per-user neutral head pose**.
- [ ] Published in an independent `HeadReading` (seam c) with **dominance/approach** context for the fused constructs; viewable alone; works in the window (no new permission).
- [ ] `build_sim` green. On-device: head pitch and tilt are shown as measured deltas from the wearer's neutral pose, not translated into feelings (head-tilt "dictionaries" are culture-coded and sign-unstable; see PRD v2 §11).

**US-HP2 · Real head 6DoF + motion energy (immersive)**
- [ ] When the immersive space is open, an ARKit `WorldTrackingProvider` device anchor supplies head 6DoF; `NSWorldSensingUsageDescription` added.
- [ ] Compute head-motion **energy** (→ arousal/engagement) and detect nod/shake; reported in `HeadReading`. "Unavailable in window" is a first-class state.

**US-HP3 · Head → dominance/approach dimension**
- [ ] `HeadReading` contributes a **dominance/approach** axis (new — the face gives it only weakly), kept distinct from valence/arousal, with uncertainty shown. Head pose must **not** drive valence (that stays on the face).
- [ ] Pride (head-back) vs. shame (head-down **+ averted gaze**) surfaced as the two well-supported felt-state displays; head-down with **direct** gaze is flagged **ambiguous** (anger-illusion), not shame. Lateral tilt is a low-confidence cue only. **No** specific-tilt→specific-emotion dictionary.

### Gaze — Tier 2 (gated)

**US-G1 · On-device gaze-fidelity probe**
- [ ] Extract `leftPupil`/`rightPupil` landmarks; HUD the iris offset within the eye.
- [ ] On-device decision: with a still head, does the iris shift when you look hard left/up, and do blinks show? **Records a yes/no that gates US-G2.**

**US-G2 · Coarse gaze proxy (only if US-G1 passes)**
- [ ] Iris offset → **gaze-aversion / downward-gaze** hint feeding the focus/effort axis (and, weakly, valence for downward gaze).
- [ ] Shipped **behind a flag**, labeled experimental/low-confidence. **No** gaze-direction→meaning dictionary.

### Fusion, modes & presentation

**US-F1 · Mode switcher + independent readouts**
- [ ] The tab/mode registry (`ImmersiveControlsView` `Demo` enum, `:15-21` — the original window hub, since replaced by `App/ContentView.swift`) gains channels: **Face / Eyes / Hands / Head / Fused**.
- [ ] Default shows channels **independently**; lifecycle per channel (hands ⇒ immersive open; eyes/face ⇒ either). On-device: switching modes starts/stops the right capture without contention.

**US-F2 · FUSE-1 Face + Eyes (with explanation)**
- [ ] Optional toggle blends eye arousal into the shared valence/arousal at `EmotionEngine.swift:221` (seam b), before the reading is built.
- [ ] UI shows the **"why"** text (§3.2). Off by default.

**US-F3 · FUSE-2 Face + Hands (with explanation)**
- [ ] Optional toggle: hand arousal/agitation blends into arousal and breaks face-valence ties at high intensity; surfaces a **congruence / "composed but activated"** state.
- [ ] UI shows the "why" text. Off by default.

**US-F4 · FUSE-3 / FUSE-4 consensus + combined reading**
- [ ] Optional all-channel reading showing **per-channel contribution** and an **arousal-consensus confidence** (agreement ↑ confidence; disagreement flagged).
- [ ] UI shows the "why" text. Off by default.

**US-F5 · Focus/effort axis**
- [ ] Orthogonal cognitive-load indicator (blink-suppression + gaze-aversion), separate from emotion, off by default, labeled low-confidence.

**US-F6 · Aura expresses the body/eye signal**
- [ ] Optional: the immersive aura pulse (`ImmersiveView.swift:39-45`) is driven by combined arousal (gesture + blink energy), not only facial intensity. Toggleable; default = current face-driven behavior.

### Cross-cutting

**US-X1 · Uncertainty everywhere**
- [ ] Every new meter shows confidence and states ambiguity in plain language (e.g., high blink = "aroused or disengaged"). No single-cue certainty.

**US-X2 · Self-tests**
- [ ] `EmotionSelfTests` extended for any new math (blink baseline, pitch correction, fusion blends, arousal-consensus). Traps on failure at launch as today.

---

## 5. Functional Requirements

1. **FR-1** The system must detect blink events from the existing eye-openness metrics without modifying `FaceGeometry`.
2. **FR-2** The system must learn and persist a **per-user baseline** for blink rate and for hand gesture/self-touch, re-runnable like the neutral-face calibration.
3. **FR-3** The system must publish **independent** `EyeReading` and `HandReading` alongside the existing `reading`, each viewable alone.
4. **FR-4** Every new affect meter must be expressed as a **delta from the user's own baseline**, never an absolute count.
5. **FR-5** Hands must be sensed via ARKit `HandTrackingProvider` in the mixed immersive space; when that space is closed, the hand channel reports **unavailable** and the app keeps working.
6. **FR-6** Fusion modes must be **opt-in and off by default**; enabling one must display its rationale text.
7. **FR-7** Fusion must only affect **valence/arousal and the valence tie-break** — it must **never** emit a new discrete emotion label.
8. **FR-8** The system must correct anger/AU4 for face pitch so a downward look does not produce false anger.
9. **FR-9** The focus/effort (cognitive-load) readout must be **orthogonal** to valence/arousal and off by default.
10. **FR-10** The Tier-2 gaze proxy must be **gated** on the on-device fidelity probe and shipped behind an experimental flag; it must never map gaze direction to a specific meaning.
11. **FR-11** The aura may optionally be driven by combined arousal; default behavior is unchanged.
12. **FR-12** New off-main analysis types (e.g. `HandAnalyzer`) must be explicitly `actor`/`nonisolated` (MainActor-default gotcha).
13. **FR-13** New authorizations (`NSHandsTrackingUsageDescription`, and `NSWorldSensingUsageDescription` if head pose is used) must be added and requested only when the relevant channel is activated.
14. **FR-14** Every new meter must display uncertainty and, where a signal is directionally ambiguous, state both readings.
15. **FR-15** The system must re-use the already-computed face pose (`FaceGeometry.swift:235-237`) as an affect signal (pitch/tilt/yaw), expressed as a delta from a per-user neutral head pose, without new permissions.
16. **FR-16** Head pose must contribute a **dominance/approach** dimension kept distinct from valence/arousal; head-motion energy may feed arousal/engagement — with no specific-tilt→specific-emotion mapping.

---

## 6. Non-Goals (out of scope)

- **No torso / shoulder / arms-at-rest / stance / leg sensing.** Physically unsensable on the headset; there is no wearer body-tracking API. (Posture is a **future maybe** — see §9.)
- **No raw gaze direction / ray / target / fixation, and no pupil dilation.** Walled off on visionOS at every tier (incl. enterprise).
- **No gesture dictionary, no gaze-direction "tells," no head-tilt dictionary, no lie detection.** Pseudoscience (spike §2, §7.4).
- **No new discrete emotion categories** from hands or eyes — they inform dimensions and tie-breaks only.
- **No mandatory/default-on fusion.** Independent channels are the default.
- **No pupillometry-based arousal** even though it's the canonical signal — we can't access it; call this out honestly in the science writeup.

---

## 7. Design Considerations

- **Modes UI:** extend the `Demo` enum + tab registry (`ImmersiveControlsView.swift:15-21`, `:25`, `:58-68`, `:241-285`). Independent channel cards; fusion toggles that reveal their rationale text; a secondary focus/effort indicator.
- **Explanations are a feature, not a footnote** — each fusion toggle shows a one-paragraph "why this combination is valid," per the developer's requirement that integrations be sensible *and explained*.
- **Aura:** one-line hook at `ImmersiveView.swift:39-45` to source arousal from the combined signal when US-F6 is on.
- **Graceful/ambiguous states** must be first-class in the visual design (an "unavailable" hand channel, an "ambiguous" blink reading).

## 8. Technical Considerations

- **Seams (from the spike):** parallel published readings for independence (seam c, `EmotionEngine.swift:34-39`); valence/arousal blend for fusion (seam b, `EmotionEngine.swift:221`); blink off `eyeOpenLeft/Right`; `HandAnalyzer` actor + `ARKitSession` in the mixed `ImmersiveView`; `WorldTrackingProvider` if head pose is added.
- **Do NOT** push hands/eyes into the 8-class log-linear softmax (seam a) — semantically wrong; hands/eyes are dimensional, not categorical.
- **Calibration** reuses the `NeutralBaseline` pattern and `UserDefaults` persistence for each new channel.
- **Concurrency:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every new off-main type explicitly marked.
- **Frame rate:** ~15 Hz throttle → blink **rate over window**, not per-blink dynamics.
- **Immersive coupling:** the hand channel requires the mixed space open — surface this as "the aura gains a hand-driven pulse when you go immersive," not a hidden dependency.

## 9. Success Metrics

- **M1** Each channel yields a **legible** signal on-device: blink rate rises under forced arousal (mental math / breath-hold) vs. calm; gesture energy separates wave / rest / face-touch. (The developer's on-device judgment — the keystone gates.)
- **M2** Each fusion mode carries a written rationale the user judges sensible; enabling/disabling fusion changes the reading in the expected direction.
- **M3** No regression in face-only behavior; `build_sim` green; `EmotionSelfTests` pass.
- **M4** The look-down false-anger case is eliminated (US-E4 test + on-device).
- **M5** The masked-affect state (calm face + agitated hands) is demonstrably surfaced in FUSE-2.

## 10. Open Questions

- **OQ-1 (gates Tier-2):** On-device — does the Persona iris visibly track real gaze with a still head, and do blinks show clearly at the capture framing? (US-G1.)
- **OQ-2:** Is blink reliably recoverable from the Persona feed at ~15 Hz, or does the throttle need raising for the eye channel? (Confirm in US-E1.)
- **OQ-3:** Is the "hands ⇒ immersive space open" coupling acceptable UX, or should hands-mode auto-open the aura space?
- **OQ-4 (future maybe):** **Posture via a paired iPhone body-cam** (ARKit `ARBodyTrackingConfiguration` → skeleton streamed to the headset) is the only route to true torso/arm/stance sensing. Noted as a **future** exploration, explicitly out of this feature's scope. Interesting enough to keep on the radar.

---

*Evidence, citations, and the platform capability tables live in `docs/design/spike-body-language-gesture.md`. This PRD consolidates that spike into buildable scope; keep the two in sync.*
