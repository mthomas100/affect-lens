# Spike — Body language, gesture & gaze as emotion channels on Vision Pro

**Status:** research spike, no code written. Six research passes (codebase, platform APIs, SOTA models, psychology; then eye-gaze platform + psychology). **2026-07-10; eye-gaze vector added 2026-07-11.**

---

## TL;DR — the reframe

1. **On Vision Pro, "body language" of the wearer = hands + head. Nothing else.** The headset is a face-mounted, inside-out sensor rig: it senses your head (6DoF) and your hands (27-joint 3D skeleton per hand) but **physically cannot see your torso, shoulders, arms-at-rest, stance, or legs**, and there is **no wearer body-tracking API** — `ARBodyTrackingConfiguration` (the iOS full-body skeleton) **does not exist on visionOS**. The upper-body motion you see on your Persona is system-synthesized and never surfaced to apps.
2. **What hands give you affectively is AROUSAL / AGITATION / ENGAGEMENT — not discrete emotions, and not much valence.** The face already owns valence + the 8-way label. So hands are **complementary, not redundant.**
3. **Deployable substrate is Apple's own ARKit `HandTrackingProvider`** — 27 joints, 3D, on-device, free. It only delivers data inside a **Full Space**, which this app already has as the *optional mixed aura ImmersiveSpace*. So hands come "for free" whenever the aura is open.
4. **Best empirical anchor:** a 2024 Quest-Pro study ("Motion as Emotion") read arousal/valence from **hand tracking alone** at ~85% *within-user*, collapsing toward chance across unseen users → **per-user calibration is essential** — which mirrors this app's existing neutral-face baseline exactly.
5. **Recommendation:** a **Face + Hands *fused* mode** where hands add an arousal/agitation axis and break face-valence ties at peak intensity. The novel win is the **"calm face, restless hands" masked-affect insight** — the whole exceeds the sum. Ship it as calibrated low-dimensional meters with honest uncertainty; **never a gesture dictionary**. Prove it with a ~1–2h keystone spike before building.
6. **Eye/gaze vector (added 2026-07-11):** raw gaze & pupil are walled off on visionOS at every tier — but your face pipeline already processes the **Persona virtual camera**, whose eyes move and blink with you. So **blink rate + eye-openness dynamics → arousal/fatigue** is a near-free, defensible add built on metrics you already extract (no blink detection exists today — that's the net-new win). Gaze *direction* is a device-fidelity gamble (avatar iris) gated on one on-device observation; gaze-direction "tells" are pseudoscience. See §7.

---

## 1. What the headset can actually sense of YOU (the hard constraint)

| Signal | On visionOS? | API | Key constraint |
|---|---|---|---|
| Head pose (6DoF) | ✅ | `WorldTrackingProvider` device anchor | Head node only — no neck/torso |
| **Hand joints (27/hand, 3D, chirality)** | ✅ **conditional** | ARKit `HandTrackingProvider` → `HandAnchor`/`HandSkeleton` | **Full Space only** + hand-tracking auth; **only while hands are in the front/lower camera frustum** — lost at your sides/behind |
| Pinch / system gestures | ✅ | SwiftUI `SpatialEventGesture` | Discrete events; works in windows too |
| Eye gaze / attention | ⚠️ system-only | none (hover/focus only) | Raw gaze never exposed (privacy) |
| Face expression | ⚠️ Persona cam only | your own CV on the front camera | No `ARFaceAnchor`/blendshapes on visionOS — exactly why this app runs its own pipeline |
| Torso lean | ❌ | — | Outside every frustum; no API |
| Shoulder posture | ❌ | — | Same |
| Arms at sides | ❌ | — | Below/behind hand-tracking FOV |
| Full-body stance | ❌ | — | `ARBodyTrackingConfiguration` is iOS-only |
| Legs | ❌ | — | Never in view |

**Frustum caveat, and why it barely hurts:** hands leave view constantly, so features must be **rate/energy over a window, robust to gaps**. Conveniently, the *affectively loud* hand moves — gesticulation and face-touching — happen **up in front of you, in view**; hands dropped to your sides (out of view) map to "at rest ≈ low arousal." The gap is mostly the low-signal state.

**If you ever want true posture/stance:** the only route is a **second device** — an iPhone facing you running ARKit `ARBodyTrackingConfiguration` (~91-joint 3D skeleton) or `VNDetectHumanBodyPose3DRequest`, streamed to the headset over the local network. That's real body language, but a materially bigger architecture and a second piece of hardware.

---

## 2. What hands actually mean (defensible science vs. pop-psych)

**Organizing finding:** the body/hands are a far better channel for **AROUSAL** than for **VALENCE**; the face is better for valence and discrete categories — *except* at peak intensity, where the face saturates and the body carries valence better (Aviezer, Trope & Todorov 2012, *Science*).

**Safe to build on:**
- **Self-touch / self-adaptor RATE ↑ = anxiety + cognitive/emotional load** (Grunwald 2014; Mohiyeddini & Semple 2013; Pang, Canarslan & Chu 2022). The single highest-value hand feature. Read as a **delta from personal baseline over a window** — never a single touch (also serves plain grooming).
- **Gesture amplitude / speed / energy ↑ = arousal / activation** (Dael, Goudbeek & Scherer 2013; Wallbott 1998). Cleanest quantitative hand feature.
- **Gesture (illustrator) RATE ↑ = engagement / involvement / enthusiasm**; ↓ with caution/boredom/low mood (Ekman & Friesen).
- **Arousal >> valence from the body** (Kleinsmith & Bianchi-Berthouze 2013 survey; Wallbott 1998). Valence recoverable only weakly, via approach/withdrawal and expansion/contraction.
- **Behavior is idiosyncratic → per-user baselining required** (Wallbott 1998; Pang 2022) — arguably *more* necessary than for the face.

**Avoid claiming (pop-psych / non-replicable):**
- A **gesture→meaning dictionary**: "arms crossed = defensive," "nose-touch = lying," "steepling = confidence," "chin-stroke = evaluation." No reliable single-cue readout (DePaulo et al. 2003: deception cues avg d≈.25 — no "Pinocchio's nose").
- Reading **valence** from an isolated hand cue.
- **Power posing** changing hormones/behavior — disavowed by the lead author (Carney 2016); only *felt* state moves, and even that is mostly "don't slump" (Ranehill 2015; Elkjær 2020/22). Irrelevant anyway (it's about *adopting* posture, and the device can't see the torso).
- Universal cross-cultural emblem meanings; any lie detection.

### Hand cues → affective meaning

| Hand cue | Defensible meaning | V/A mapping | Confidence | Headset-sensable? |
|---|---|---|---|---|
| Self-touch **rate** vs. own baseline | anxiety, discomfort, cognitive load | ↑ Arousal (load) | **Med** — replicated, but small effects, grooming confound | Yes (hand→head proximity in FOV) |
| Gesture **amplitude / speed / force** | emotional activation, potency | ↑ Arousal (**strong**) | **Med–High** (acted corpora) | Yes — cleanest feature |
| Gesture / illustrator **rate** | engagement, enthusiasm | ↑ Arousal/engagement | **Med** (speech-confounded) | Yes |
| Open palm vs. clenched/hidden | openness vs. tension | weak V + A, high intensity only | **Low** (mostly pop-psych) | Yes (aperture) but fragile |
| Hand-to-face "thinking" | **cognitive load / self-soothing** (not "doubt") | ↑ Arousal (load) | **Low** for specific meaning | Yes on approach; device occludes contact point |

**Fusion recipe the science implies:** face → **valence + discrete label**; hands → **arousal + engagement/agitation**; and when facial valence confidence collapses at high intensity, let hand tension/energy **break the valence tie**. Genuinely complementary, not redundant.

---

## 3. What's buildable, and where it plugs in

**Substrate:** ARKit `HandTrackingProvider` (27 joints, 3D, on-device, free). Needs a Full Space + `NSHandsTrackingUsageDescription` authorization. **The app's mixed aura `ImmersiveSpace` is a Full Space → hands work whenever it's open.** (The main window, in the shared space, gets no raw hand joints — only system pinch.)

**Derived per-frame scalars → per-user-baselined features:**
- mean joint speed (hand-motion **energy**) → arousal
- hand aperture / openness → weak valence/tension
- min hand-to-head distance / contact events → **self-touch** → agitation/load
- gesture rate over a window → engagement

Mirror the existing `NeutralBaseline` pattern with a **hand baseline** (resting self-touch rate, resting gesture rate/amplitude), persisted in `UserDefaults` like the face baseline. An absolute self-touch count is near-meaningless; a within-person **rate increase** is the signal.

**Integration seams** (from the codebase review — easiest → hardest):
- **(c) Parallel `GestureReading` published beside `reading`** (mirrors how `auVector`/`overlay` already ride alongside `reading`, `EmotionEngine.swift:34-39`). Lowest risk; a new view observes it; one line at `ImmersiveView.swift:39` also drives the aura. **Recommended start.**
- **(b) Blend gesture (valence, arousal) into the VA channel** in `EmotionEngine.apply` — VA is a pure function of the distribution today (`let va = smoothedDist.valenceArousal`, `EmotionEngine.swift:221`); add a small EMA state next to `smoothedIntensities`. **Best affective fit for the fused mode.**
- **(a) Another expert in the 8-class log-linear fusion** (`EmotionDistribution.fused`, `EmotionTypes.swift:171`). Mechanically trivial, **semantically wrong** — hands→discrete-emotion is fragile. Avoid.

**Idiomatic shape:** a `HandAnalyzer`/`GestureAnalyzer` **actor** mirroring `FaceAnalyzer`, but consuming an `ARKitSession` anchor stream (not a `CVPixelBuffer`). Remember `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — mark it `actor`/`nonisolated` explicitly or Vision/ARKit work silently hops back to main.

---

## 4. Modes (should the app have modes?)

- **Face only** — today's default. Discrete emotion + valence/arousal from the Persona cam. Works in the window; no immersive space needed.
- **Hands only (Gesture)** — arousal + agitation + engagement meters, **no discrete label**. Requires the immersive space open. This is the *honest* version of a body-only mode — it's **hands, not posture**.
- **Face + Hands (Fused)** — the recommended flagship. Face = label + valence; hands = arousal/agitation/engagement + valence tie-break at intensity. Unlocks **congruence / masked-affect** ("calm face, restless hands").

**Coupling to surface:** any hands mode implies the immersive space is open (that's the only place ARKit data flows). Reframe as a feature, not a cost: *the aura gains a hand-driven pulse when you go immersive.*

---

## 5. Body language for the avatar

Two distinct senses:
- Your **Persona** (the system avatar in FaceTime/SharePlay) **already has body language** — visionOS synthesizes arm/hand/upper-body motion from the same hand tracking. You don't control or read it; it's system-private. So in the shared-space sense, the avatar already gestures.
- Our **own representation** (aura + dashboard, and any avatar we render) **should** gain a body/gesture dimension: aura pulse from hand-motion energy (arousal), an agitation meter from self-touch, an engagement meter from gesture rate. That's the real opportunity, and it's cheap once the signal exists.
- A literal **mirror-avatar** showing YOUR posture back to you needs the third-person iPhone body-cam (§1) — out of scope for the on-device solo path.

---

## 6. The keystone spike (prove or kill, ~1–2h on device)

Remaining load-bearing unknowns: (1) hand data actually flows well inside **this app's mixed space**; (2) simple hand features are **legible as arousal/agitation** despite frustum gaps.

**Smallest test:** in the existing mixed `ImmersiveSpace`, add an `ARKitSession` + `HandTrackingProvider`; compute and HUD three scalars per frame —
- mean joint speed (energy),
- hand aperture (openness),
- min hand-to-head distance (self-touch proxy).

Do **wave / rest / face-touch** produce clearly separable, legible traces?
- **Yes** → build per-user-baselined `(arousal, agitation, engagement)` as a parallel `GestureReading` (seam c), drive the aura, then optionally blend into VA (seam b) for the fused mode.
- **No** (too noisy/gappy) → kill or rethink.

No model training needed — it's pure geometry off the joint stream.

---

## 7. Added vector — Eye gaze & eye behavior (2026-07-11)

Two more research passes (platform + psychology). The finding is a clean three-tier split — and, neatly, **the tier that's scientifically bogus is exactly the tier the hardware denies.**

### 7.1 The capture crux (resolved)
The app's front `.builtInWideAngleCamera` is really the **Persona virtual camera** — the FaceTime avatar-webcam feed (`// the user's Persona fills the frame`, `FaceAnalyzer.swift:40`). The Persona is **driven in real time by the headset's internal eye + face trackers, blinks and eye movement included** — so your eyes moving/blinking are *already latent in the pixels the app processes*, one abstraction removed as avatar pixels. (Front-camera capture was blocked "for privacy" on visionOS 1.x per older forum threads; it works on 26, which the developer's on-device use confirms.)

**The one device-only unknown (gates Tier 2):** how faithfully the Persona re-renders *fine gaze direction* (iris vector) and *blink aperture* at the virtual-camera framing. → **Open question for the on-device test:** *in a captured Persona frame, do the eyes visibly dart and blink; and when the wearer looks hard left/up with the head held still, does the avatar iris shift — or stay locked forward?*

### 7.2 What's available (platform)
| Signal | To apps on visionOS 26? | Mechanism | Note |
|---|---|---|---|
| Raw gaze direction / ray / target / fixation | ❌ | — | "Where you look stays private"; hover/focus rendered by the system, target never revealed |
| Pupil diameter / dilation | ❌ | — | Internal IR eye cams inaccessible at every tier incl. enterprise |
| Eye **expression** (lid aperture, widen, squint) | ✅ already | Vision landmarks on the Persona image | `eyeOpenLeft/Right` computed (`FaceGeometry.swift:189-190`); AU5/6/7 computed (`ActionUnits.swift:124-131`) |
| **Blink / eye-closure** | ✅ derivable | threshold `eyeOpenLeft/Right` + temporal pattern | **No blink detection today** (no AU43/45) — net-new |
| Avatar **iris position** (crude gaze proxy) | ⚠️ device-fidelity gamble | Vision `leftPupil`/`rightPupil` landmarks (currently ignored) | fidelity = the crux unknown (§7.1) |
| Head pose (gross look up/down/side) | ✅ | ARKit `WorldTrackingProvider` device anchor | headset orientation, not eyes; needs Full Space |

### 7.3 Three tiers
- **Tier 1 — near-free & defensible (recommend):** **blink rate + eye-openness dynamics → arousal / fatigue / attention**, built on `eyeOpenLeft/Right` already extracted (a blink detector reads them directly, no `FaceGeometry` change). Plus the eye-expression AUs (AU5 widen→surprise/fear, AU6 Duchenne→often associated with positive affect (not a genuineness marker), AU7 squint→anger/scrutiny, AU43 closure→disengagement) already feed the classifier — that *is* the defensible "eye emotion."
- **Tier 2 — device-fidelity gamble:** **avatar iris → crude gaze-direction proxy** (extract the unused Vision pupil landmarks). Only worth it if the §7.1 observation shows the Persona preserves gaze; even then, map to coarse **gaze-aversion / downward-gaze**, never a direction dictionary.
- **Tier 3 — walled off + pseudoscience:** raw gaze rays, pupil dilation, gaze-direction "tells." No API, and no defensible meaning to lose.

### 7.4 What the eye actually means (defensible vs. pseudoscience)
| Eye cue | Defensible meaning | V/A mapping | Confidence | Sensable here? |
|---|---|---|---|---|
| **Blink rate ↓** vs. own baseline | focused visual attention / concentration | attention ↑ (external) | **Med-High** (fairly specific) | Yes, if blink recoverable |
| **Blink rate ↑** vs. own baseline | arousal / anxiety / stress — *or* fatigue / disengagement / speaking | Arousal ↑ (**direction ambiguous**) | **Med** | Yes, baselined |
| Eye widen (AU5) | surprise, fear, vigilance | Arousal ↑ | **High** | Yes — already an AU |
| Lid tighten / squint (AU7) | anger, disgust, scrutiny | neg valence | **Med-High** | Yes — already an AU |
| Duchenne AU6 (+AU12) | often associated with positive affect (intensity-confounded) | Valence + | **High** | Yes — already an AU |
| Prolonged closure (AU43) | withdrawal, boredom, fatigue | Arousal ↓ | **Med** | Yes (net-new) |
| Gaze aversion (look away while thinking) | **cognitive load / internal focus — NOT evasion** | orthogonal *focus* axis | **High** | Weak (no raw gaze; head-turn proxy) |
| Downward gaze / head pitch-down | sadness, submission, shame | neg / withdrawn | **Med** | Partial via head/face pitch |
| **Gaze-direction "tells"** (up-left = recall, look-X = lying) | **none — pseudoscience** | — | **Debunked** (Wiseman 2012) | Moot (walled off anyway) |

Two rules fall out: (1) **blink & gaze-aversion are an *attention/effort* axis — keep them orthogonal to valence/arousal** (mirrors the app's intensity-vs-confidence separation); expose as a low-confidence "focus/effort" reading, off by default. (2) **Pupil is the canonical arousal signal we deliberately can't use** — say so in the science writeup to pre-empt "why not pupils?".

### 7.5 Bonus bug caught
Looking **down** tilts the face so the brow reads as a lowered V-shape (AU4-like) → **inflates perceived anger** — the AU4 "imposter" (Witkower & Tracy 2019 *Psych Science* on dominance; 2020 *Emotion* on anger). So down-pitch should **discount, not amplify**, geometric anger. Worth fixing regardless of this feature. Note it's **gaze-gated**: head-down reads as *shame* only when gaze is averted; with direct gaze it's the anger-illusion.

### 7.6 Eye keystone test (folds into the hand one)
Add a rolling **blinks/min** + eye-openness-variance HUD off the existing `eyeOpenLeft/Right`; verify blinks register and rate rises under forced arousal (breath-hold / mental math) vs. calm — and simultaneously answer the §7.1 gaze-fidelity observation. ~1h, no new entitlement.

### 7.7 Related vector — head pose & tilt (added 2026-07-11)
The Persona face's **yaw/roll/pitch is already computed** (`FaceGeometry.swift:235-237`, roll-correction only today); real head **6DoF** (gravity-referenced, + motion energy / nod-shake) comes from `WorldTrackingProvider` in the immersive space. **Head pose's job is dominance/approach + arousal — not valence (leave valence to the face).** Two *well-supported felt-state* displays (spontaneous, cross-cultural, present in congenitally-blind people ⇒ innate — Tracy & Matsumoto 2008): **head-back + expanded → pride / dominance**; **head-down + gaze-averted → shame / submission**. Weaker/dimensional: yaw toward/away → approach/aversion; **head-motion energy → arousal** (scalar); **lateral tilt is the most over-claimed cue** (sign-unstable, smile/gender-confounded — low-confidence only). Two caveats: **(1) pitch is gaze-gated & non-monotonic** — head-down reads shame *only* with averted gaze; with direct gaze it spoofs anger/dominance via the AU4-brow illusion (Witkower & Tracy 2019/2020), so head-down is ambiguous without gaze (ties to the gaze tier). **(2)** that same illusion means **down-pitch should discount geometric anger** — the mechanism behind the §7.5 fix. Per-user-baselined (deviation from the user's own neutral head pose). Head pose is the **best channel for a dominance/approach axis** — one the face gives only weakly. Folded into the PRD as Channel 4.

---

## 8. Open decisions

**Hands / body:**
- **Scope:** hands-only vs. fused (recommend **fused**).
- **Posture ambition:** accept hands-only forever (on-device solo), or plan for true posture later via the iPhone body-cam architecture?
- **Coupling:** OK that "hands mode ⇒ immersive space open"?

**Eyes / gaze:**
- **On-device observation (gates Tier 2):** does your Persona's iris visibly move when you look around with a still head, and do blinks show? (§7.1)
- **Tier scope:** ship Tier 1 (blink + eye dynamics → arousal) only, or also gamble on Tier 2 (avatar-iris gaze proxy)?
- **Focus/effort axis:** want an orthogonal cognitive-load readout (blink/aversion-based), or keep the app purely emotional?

**Head pose (added vector):**
- **Near-free:** surface the already-computed face pose as a dominance/approach + interest signal? (recommend yes)
- **Immersive extra:** add real head 6DoF for motion-energy / nod detection when the aura is open?

**Both:**
- **Honesty bar:** low-dim calibrated meters + uncertainty; **no gesture dictionary, no gaze-direction dictionary, no pupil, no lie-detection.**
- **Anger/pitch fix:** worth doing now regardless (§7.5).

---

## Sources (key)

Ekman & Friesen 1969 (*Semiotica*, nonverbal taxonomy) · Birdwhistell 1970 (*Kinesics and Context*) · Grunwald 2014 (*Brain Research*, self-touch/EEG) · Mohiyeddini & Semple 2013 (self-touch/anxiety, TSST) · Pang, Canarslan & Chu 2022 (*J. Nonverbal Behavior*) · Dael, Goudbeek & Scherer 2013 (gesture dynamics) · Dael, Mortillaro & Scherer 2012 (BAP coding) · Wallbott 1998 (*EJSP*, bodily expression) · Kleinsmith & Bianchi-Berthouze 2013 (*IEEE T-Affective Computing* survey) · de Gelder 2006 (*Nat Rev Neurosci*, emotional body language) · Aviezer, Trope & Todorov 2012 (*Science*, body breaks valence at peak intensity) · DePaulo et al. 2003 (*Psych Bulletin*, cues to deception) · Power posing: Carney/Cuddy/Yap 2010, Ranehill 2015, Simmons & Simonsohn 2017, Carney 2016 disavowal, Elkjær 2020/22 meta · "Motion as Emotion" 2024 (Quest Pro hand-tracking affect, arXiv 2409.12921) · Apple: ARKit in visionOS, `HandTrackingProvider`, `WorldTrackingProvider`, enterprise main-camera access (WWDC23/24/25).

**Eye/gaze (added 2026-07-11):** Glenberg et al. 1998 & Doherty-Sneddon & Phelps 2005 (gaze aversion = cognitive load, not evasion) · Semyonov et al. 2019 (downward gaze ↔ sadness) · Adams & Kleck 2003/05 (shared-signal, approach/avoidance) · Senju & Johnson 2009 (eye-contact effect) · blink rate: Chidi-Egboka et al. 2023 (*IOVS*), Jongkees & Colzato 2016 (blink↔dopamine review) · pupillometry (context-only, unavailable): Hess & Polt 1960/64, Kahneman & Beatty 1966, Beatty 1982 · **Wiseman, Watt et al. 2012 (*PLOS ONE*, NLP eye-accessing-cues debunk)** · Witkower & Tracy 2020 (head-pitch AU-imposter → false anger) · McCarthy et al. 2008 & Akechi et al. 2013 (cultural gaze norms) · Apple visionOS 26: gaze privacy (forums 750745), Persona virtual camera capture (forums 749810), Look to Scroll (WWDC25 s317).

**Head pose (added 2026-07-11):** Darwin 1872 · Tracy & Robins 2004/07 & **Tracy & Matsumoto 2008** (*PNAS*, pride/shame innate — congenitally-blind athletes) · Tracy & Robins 2008 (*JPSP*, cross-cultural pride) · **Witkower & Tracy 2019** (*Psych Science*, head-tilt AU4 "imposter" → dominance) & **2020** (*Emotion*, head-down → angrier) · Witkower et al. 2020 (*JPSP*, prestige vs. dominance displays) · Mignault & Chaudhuri 2003 (head tilt → dominance/emotion) · Toscano et al. 2018 & Zhang et al. 2020 (gaze × head-pose jointly gate dominance) · Otta 1994 & Torrance et al. 2020 (lateral-tilt effects are weak/dissociable) · Keltner 1995 (embarrassment = head down+away) · McClave 2000, Cowie et al. 2010, Osugi & Kawahara 2018 (nods/shakes: affective tone reliable, propositional meaning culture-coded).
