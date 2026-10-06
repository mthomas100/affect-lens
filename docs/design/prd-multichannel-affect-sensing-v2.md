# PRD v2 — Multi-channel affect sensing & fusion (channel lenses + combined modes)

**Status:** Draft for the developer's review · **Date:** 2026-07-11 · **App:** AffectLens, developed as Facial Computing (visionOS 26, Apple Vision Pro)

**Supersedes:** `docs/design/prd-multichannel-affect-sensing.md` (PRD v1, 2026-07-11). v1 stands as the buildable-scope consolidation of the spike; **v2 replaces it** with the full affect-fusion wave's evidence: a validated channel inventory (v1's 4 channels → 7 + a ground-truth loop + an interpreter), named greater-than-sum fused constructs, a chosen fusion-engine architecture with rejected alternatives, an uncertainty-display grammar, and an 11-step zero-regression integration ladder. Where v1 and v2 disagree, **v2 governs**; the "Changed vs v1" note (§0.3) is the diff.

**How to read this doc (the evidence base):**
- The load-bearing science, platform truth, and citations live in **`docs/design/spike-body-language-gesture.md`** (the spike) and in the wave's longer research notes (not published in this repo; references below of the form "research notes §3.1" point into them). This PRD is the *buildable contract*; for every code claim it cites a verified `file:line` (as of 2026-07-11).
- **Honesty bar (law, inherited from the spike, non-negotiable):** per-user baselining everywhere; low-dimensional calibrated meters with visible uncertainty; **NO** gesture dictionary, **NO** gaze-direction tells, **NO** head-tilt/nod dictionary, **NO** pupil claims, **NO** lie/deception detection, **NO** clinical (stress/anxiety/depression) labels. Barrett et al. 2019 taken seriously: expressive cues are *probabilistic, person- and context-variable evidence*, never 1:1 emotion readouts.
- **The one truth that reframes everything (`[established]`):** the "face" channel is **not the real face** — it is the **rendered Persona avatar**, read off `AVCaptureDevice.systemPreferredCamera`. Every AU is an *AU-of-the-Persona*, already ML-compressed before the app sees a pixel. The per-user baseline absorbs some of this; **UI copy must say "from your Persona," never "your face."**

---

## 0. Supersession & scope

### 0.1 Mandate
Research + PRD only. **No implementation, no code changes in this wave.** This document specifies what to build next; the build follows the phased roadmap (§8) under this repo's verification idiom (`build_sim` green + `EmotionSelfTests` extended + on-device checks by the developer — **no simulator E2E**).

### 0.2 One-line
Expand the app from a single face reading into **independent per-channel "lenses"** (each showing raw stream → derived features → honest interpretation) plus **opt-in fusion modes** that combine 2+ channels into **named, science-backed constructs greater than the sum** — every fused insight showing its contributing channels and confidence, never a black box.

### 0.3 Changed vs v1, and why
| # | v1 said | v2 says | Why (evidence) |
|---|---|---|---|
| C1 | 4 channels: Face, Eyes, Hands, Head | **7 sensing surfaces**: + **Voice** (mic → SoundAnalysis + DIY prosody → arousal), + **Interaction dynamics** (`SpatialEventGesture`, zero-permission, windowed), + **Context** (thermal/session/time); plus **HKStateOfMind** ground-truth loop and a **FoundationModels** interpreter | Voice is the highest-ROI channel v1 missed and is fully on-device (research notes §1.1, §2.5); interaction dynamics is a zero-permission windowed load/engagement meter (research notes §1.1); both validated this wave |
| C2 | Fusion modes named FUSE-1…4 (generic blends) | **Named scientific constructs**: Composure-under-load/Channel-Divergence, Cognitive-Load, Fatigue⇄Engagement, Frustration, Frown+Head-down, Corroborated-Positivity, Approach/Withdrawal | Each construct is mechanistically anchored (research notes §3.1); the brief asked for *greater-than-sum, science-backed constructs*, not generic blends |
| C3 | "Fusion moves the dimensional axes" (informal) | A **layered probabilistic fusion engine** (5 layers, extension of `EmotionEngine`) with a **congruence/incongruence engine**, confidence algebra, and an `AffectEvent` bus | The wave chose and de-risked a concrete architecture (research notes §4, §8); it is an *extension, not a rewrite* |
| C4 | Availability noted per channel | **Bimodal availability is the binding design constraint** — 6 always-windowed pairs vs immersive-gated pairs; every construct declares a windowed MVV + immersive-enhanced tier | This partitions the entire combination space and dictates what ships in the default app (research notes §1.2, §3.2, §3.10) |
| C5 | Pitch/anger fix = "quick win" (§3.4) | **Pitch-correction is ladder step 0 and a hard prerequisite** for every brow/anger/head construct; the pitch is *already extracted but discarded* | `FaceGeometry.swift:237` produces pitch; `AUComputer.compute` (`ActionUnits.swift:97`) never receives it; AU4 at `ActionUnits.swift:119-122` throws it away (research notes §8.2) |
| C6 | Modes off by default, "why" text shown | Kept — **plus** a linted honesty-phrasing library, a disambiguation-ladder widget, VSUP/quantile-dotplot uncertainty grammar, and the refused-list as a shipped feature | The UX grammar already exists in-app and only needs extending (research notes §7) |
| C7 | Success = legible signals on-device | Kept — **plus** an ESM→HKStateOfMind per-user ground-truth loop and a golden-trace record/replay harness that *is* the `EmotionSelfTests` fixture | The only honest per-user accuracy claim + off-device CI-gradable regression (research notes §4.5) |

**What v1 got right and v2 carries forward verbatim:** the four honesty rules; "hands/eyes carry arousal/attention, not new discrete labels"; "fusion never invents a discrete emotion label"; the graceful-degradation mandate; the seam map (parallel readings = seam c; V/A blend = seam b; **never** push non-face channels into the 8-class softmax = seam a); the reuse of the `NeutralBaseline`/`UserDefaults` calibration pattern.

---

## 1. Vision & product theses

### (i) CHANNEL LENSES — every channel independently enableable, each a full lens
Each affect channel is a **lens** the user can turn on alone, showing **all the data that channel can give** across three strata (research notes §7.2):
1. **RAW stream** — the live signal (hand-skeleton ghost, eye-openness/blink trace, head-pose gimbal, live AU bars). Collapsible.
2. **DERIVED features** — delta-from-baseline meters (blinks/min Δ, gesture energy, self-touch rate, head-motion energy).
3. **CALIBRATED interpretation** — one or two low-dimensional meters (arousal, attention…) each with a confidence band, an ambiguity label, and a persistent one-paragraph "what this can / can't tell you."
Interpretation is always visible; raw is collapsible. This makes the brief's core request (see every piece of data a channel can give) structural.

### (ii) FUSION MODES — opt-in 2+ channel combinations yielding named constructs greater than the sum
Fusion is a set of **toggles, off by default** (except the face lens). Each mode is a **named, mechanistically-anchored construct** — e.g. *"Composed but activated"* (near-neutral face WHILE blink-rate and hand-energy climb; Gross & Levenson 1993) — that **no single channel can measure**. That un-measurable-alone property is precisely the greater-than-the-sum result the project is after. Master law (research notes §2): the **face owns valence + the discrete label**; **every other channel owns AROUSAL + one modulator** (head→dominance/approach, hands→agitation/load, eyes→attention/fatigue, voice→arousal, interaction→effort/engagement). The richest constructs marry the face's valence to a **non-face arousal/direction axis the face physically cannot give**.

### (iii) LEGIBLE FUSION — contributing channels + confidence, never a black box
Every fused insight shows **which channels contributed, with what weight, at what confidence** — rendered as ghost-dots + pull-lines on the circumplex (each channel's vote visible), a congruence ring (tightens/brightens on agreement, widens/desaturates on conflict), and a disambiguation-ladder card that shows the claim *narrowing* while greying out the confound being ruled out (research notes §7.4, §7.6). The contribution weights **are** the fusion math's live reliability vector, so the visualization doubles as an audit of the engine.

### (iv) THE HONESTY BAR AS A PRODUCT FEATURE
The refusals are not fine print — they are the differentiator. The app **publishes what it will not infer** (the refused-combinations list, §4.5), speaks in **expression estimates** ("your Persona shows…") never felt emotion, renders **uncertainty as a first-class meter** (VSUP desaturation, quantile dotplots, forked ambiguity labels), and runs **entirely on-device** — which, post the Nov-2025 App Review 5.1.2 third-party-AI-consent revision (research notes §1.2), is a concrete competitive **moat**, not just a privacy stance. Novelty verdict (research notes §5.2, `[probable]`): *"multi-channel honest affect fusion from Persona pixels + hands + head on a biosensor-free HMD with no raw face/eye API, with visible uncertainty"* is an unoccupied cell — Omnicept, emteq, and Hume each satisfy only part.

---

## 2. Channel inventory — the verified truth table

Availability is **BIMODAL and this binds the design more than the science does** (research notes §1.2): FACE / EYES / VOICE / INTERACTION / CONTEXT work in the **shared-space window** (where the app lives by default); HANDS / HEAD-6DoF / room-context only when the **aura `ImmersiveSpace` is open**.

### 2.1 Sensing channels (what a 3rd-party app can actually get on visionOS 26)
| Channel | Available? | API / mechanism | Space | Permission | Rate | Owns (affect) | Conf |
|---|---|---|---|---|---|---|---|
| **Face (Persona pixels)** | ✅ only route | `AVCaptureDevice.systemPreferredCamera` → `AVCaptureVideoDataOutput` (CMSampleBuffers) → `VNDetectFaceLandmarksRequest` | window | `NSCameraUsageDescription` + `requestAccess(.video)`, green dot | ~15 Hz (app throttle `EmotionEngine.swift:47`) | **valence + discrete label** | established |
| **Eyes / blink** (new lens; same feed) | ✅ | Threshold + temporal pattern on `eyeOpenLeft/Right` (`FaceGeometry.swift:189-190`); AU5/6/7 exist (`ActionUnits.swift:124-131`); AU43/45 net-new | window | (none beyond camera) | ~15 Hz | **attention / fatigue** (arousal via rate) | probable |
| **Hands** (27 joints, 3D, chirality) | ✅ **immersive-only** | ARKit `HandTrackingProvider` → `HandSkeleton.JointName` | **Full/Immersive Space** | `NSHandsTrackingUsageDescription` | 90–120 Hz | **agitation / load / engagement** (arousal) | established |
| **Head 6DoF pose** | ✅ **immersive-only** | `WorldTrackingProvider.queryDeviceAnchor(at:)` → `DeviceAnchor` (pitch/yaw/roll + motion energy) | Immersive | mostly prompt-free once provider runs | ~90 Hz | **dominance / approach + arousal** | probable |
| Face-pose-in-image (yaw/roll/pitch) | ✅ | `VNFaceObservation` — **already computed** (`FaceGeometry.swift:235-237`), used only for roll-correction today | window | (camera) | ~15 Hz | pitch-correction + coarse dominance | established |
| **Voice** (mic) — **NEW** | ✅ | `AVAudioEngine` inputNode tap; **foreground-only** | window | `NSMicrophoneUsageDescription` + `AVAudioApplication.requestRecordPermission`, green dot | stream | **arousal only** | API established; **channel gated on K6** |
| Sound events (laughter/cry) | ✅ on-device | `SoundAnalysis` `SNClassifySoundRequest` + `SNAudioStreamAnalyzer`, 300+ classes | window | mic | 0.5–15 s windows | corroboration (F6) | established |
| Prosody (F0/jitter/shimmer/rate) | ⚠️ DIY | NOT exposed by any Apple API → compute via Accelerate/vDSP (YIN/autocorrelation) | window | mic | stream | arousal | established |
| **Interaction dynamics** — **NEW** | ✅ | SwiftUI `SpatialEventGesture` → `SpatialEventCollection.Event` (id, timestamp, phase incl. **cancelled**, kind, location3D) | window | **none** | event | **effort / engagement / frustration** | established |
| **Context** (thermal/session/time) — **NEW** | ✅ | `ProcessInfo.thermalState`, `ScenePhase`, `Date`, audio RMS | window | none | poll | governor + data-quality | probable |
| **HKStateOfMind** (ground-truth loop) | ✅ visionOS 2+ | `HKStateOfMind(date:kind:.momentaryEmotion, valence:−1…1, labels:[…], associations:[…])`, `healthStore.save()` | window | `NSHealthShare/UpdateUsageDescription` + HealthKit entitlement | 1-tap | per-user ground truth + conformal set | API established (init verified from headers/binding); **WRITE on visionOS 26 = §10 verify** |
| **Foundation Models** (interpreter, not a channel) | ✅ visionOS 26 | `SystemLanguageModel.default.availability`; `LanguageModelSession`; `@Generable`/`@Guide`; 4096-token combined context (TN3193) | any | availability-gated | ~20–40 tok/s* | narration only | established (API); latency speculative |

\* Community, unofficial (llmcheck.net, apple-silicon-llm-bench) — **no official thermal number; treat as speculative until K5**.

**On the "Conf" column:** it rates **API existence**, not channel FEASIBILITY. An "established" API can still ride an unproven channel — per-channel feasibility is gated by the Phase-0 keystones (voice→K6, hands↔camera→K1, windowed-pitch→K3, Persona bandwidth→K4, FM latency→K5), and HKStateOfMind-**WRITE** on visionOS 26 is a §10 verify-item. Where the two diverge, the cell says so.

### 2.2 The explicit NON-channels (refused by hardware or honesty — say so in-product)
| Non-channel | Why unavailable | Confidence |
|---|---|---|
| Torso / shoulders / arms-at-rest / stance / legs | No wearer body-tracking API; `ARBodyTrackingConfiguration` is iOS-only; outside every frustum | established |
| ARFaceAnchor / 52 blendshapes | Absent on visionOS (iOS/TrueDepth only) — *why the app runs its own CV* | established |
| Raw gaze direction / ray / target / fixation | System-side; hover/focus rendered outside the app process; `onHover`/`onContinuousHover` never fire; "where you look stays private" | established |
| **Pupil diameter / dilation** | Internal IR eye-cams inaccessible at **every** tier incl. enterprise — *the canonical arousal signal we deliberately cannot use; say why to pre-empt "why not pupils?"* | established |
| Live cardiac (HR/HRV) real-time | Watch↔iPhone workout mirroring does not reach Vision Pro; HealthKit reads are minutes-stale | probable |
| Enterprise raw world camera | `CameraFrameProvider` faces outward, managed entitlement an indie can't get, blocks consumer distribution | established |
| Digital Crown / immersion level / keyboard timing | Not app-readable | established |

**Gold nuggets carried into design:** HKStateOfMind = Apple's own affect ontology → per-user ground truth; VOICE = highest-ROI missing channel, fully on-device; interaction-dynamics = zero-permission windowed load meter; `DeviceFitStatus` = free data-**quality** signal (poor fit → widen AU uncertainty); the thermal governor is a **real scheduler** (§8.5).

---

## 3. Independent lens specs (per channel)

Every lens follows the 3-strata `ChannelLensView<Raw, Features, Interpretation>` (§6.1). Each publishes its own `ChannelReading` and is viewable alone. Calibration mirrors the face's `NeutralBaseline` (median-of-36 ritual, `UserDefaults`, `ActionUnits.swift:174-193`).

### 3.1 FACE lens (exists — reframed)
- **Raw:** Persona image + landmark overlay + 14 live AU bars (`AUMetersView` exists).
- **Features:** 14 FACS AUs as deltas from `NeutralBaseline`; roll-corrected, IOD-normalized geometry (`FaceGeometry`).
- **Interpretation:** posterior over 8 emotions (EMFACS prototypes + FER+ expert, log-linear fused) + valence/arousal + intensity(aleatoric)/confidence(epistemic) kept separate.
- **Science:** constructionist frame (Barrett et al. 2019, *PSPI* 20:1) — a bare categorical label is indefensible; output must be posterior + V/A + confidence + baseline + context tag. **Drop any genuine-vs-fake-smile feature** — Duchenne/AU6 is an *intensity artifact*, not a genuineness marker (Girard et al. 2021; Krumhuber & Manstead 2009: 70% felt vs 83% posed smiles were Duchenne). Optionally seed EMFACS with Du, Tao & Martinez 2014 (PNAS) 15 compound-expression templates, labeled *"expression configuration," not felt emotion*.
- **Ambiguity state:** poor Persona fit (`DeviceFitStatus`) → widen all AU uncertainty + "signal quality low" banner.
- **Accuracy ceiling to design to (research notes §4.1, Allognon 2020):** visual-only **valence CCC ≈ 0.516, arousal CCC ≈ 0.264** → face valence is the strong signal; **face arousal is weak and must be shown with visibly wider uncertainty** (the quantile dotplot, §6.7) or reconstructed from motion/voice.

### 3.2 EYES / BLINK lens (new — the near-free Tier-1 win)
- **Raw:** eye-openness trace + blink ticks (off `eyeOpenLeft/Right`, `FaceGeometry.swift:189-190` — **no FaceGeometry change**).
- **Features:** blinks/min as **delta from a per-user baseline** (~15–20/min resting; Jongkees & Colzato 2016); eye-openness variance; prolonged-closure flag (AU43/PERCLOS). Blink detector = adaptive-EAR math (Soukupová & Čech 2016): threshold as a fraction of per-user open-eye baseline + N-consecutive + refractory; expose **blinks/min over a rolling 60 s window**, not per-blink duration (survives the ~15 Hz throttle).
- **Interpretation:** **attention / fatigue axis, orthogonal to valence/arousal.** Blink is **directionally ambiguous alone** — low = engaged OR early-task; high = fatigue/anxiety OR mind-wandering (Maffei & Angrilli 2018; Wierwille 1994) → **strong in fusion, weak alone**; always renders both readings when ambiguous.
- **Science:** attention *suppresses* blinks; sustained-task fatigue *raises* them from ~4th minute; prolonged closures/PERCLOS = textbook fatigue index. **Gaze-aversion = cognitive load, NOT evasion** (Doherty-Sneddon & Phelps 2005). Existing AUs already carry eye emotion: AU5 widen→surprise/fear, AU7 squint→anger/scrutiny, AU43 closure→withdrawal/fatigue (net-new).
- **Ambiguity/availability:** blink discounted during speech (voice VAD gate, if voice live); "blink ambiguous" is a designed state.

### 3.3 HANDS lens (new — immersive-only; arousal/agitation/engagement)
- **Raw:** hand-skeleton ghost (HandVector 2.0 `FingerShape`, MIT — 5 normalized [0,1] curls/finger).
- **Features (delta-from-baseline over a window, robust to frustum gaps):** mean joint speed (motion **energy**) → arousal; hand aperture → weak valence/tension; min hand-to-head distance / contact → **self-touch rate**; gesture rate → engagement. Needs an **emteq-style max-intensity ritual** (5× gestures/self-touch) since resting rate ≠ dynamic range.
- **Interpretation:** arousal / agitation / engagement, each a delta from the per-user hand baseline.
- **Science:** self-touch/self-adaptor **rate↑** = anxiety + cognitive/emotional load (Grunwald 2014; Mohiyeddini & Semple 2013; Pang 2022) — the highest-value hand feature, read as a **rate delta, never a single touch**. Gesture amplitude/speed/energy↑ = arousal (Dael 2013; Wallbott 1998). Motion-as-Emotion (Chua et al. 2024, arXiv 2409.12921, N=22): hand-only affect classified 50–87% **within-user**, **collapsing to chance leave-one-user-out** → *empirical proof per-user baselining is mandatory*.
- **Availability:** `.unavailable` when the aura space is closed — a first-class greyed lens with an inline CTA ("Hands need the immersive space — open it; the aura gains a hand-driven pulse"), **never faked**. Frustum caveat barely hurts: the affectively-loud moves (gesticulation, face-touch) happen in view; hands-at-sides ≈ low arousal.

### 3.4 HEAD lens (new — face-pose windowed; 6DoF immersive)
- **Raw:** head-pose gimbal (windowed: `VNFaceObservation` yaw/roll/pitch, `FaceGeometry.swift:235-237`; immersive: `WorldTrackingProvider` 6DoF + motion energy).
- **Features (delta from per-user neutral head pose):** pitch (down/up), yaw-away, lateral tilt (roll), head-motion energy.
- **Interpretation:** **dominance / approach + arousal — NOT valence (leave valence to the face).** Two *well-supported, innate* felt-state displays (present in congenitally-blind athletes — Tracy & Matsumoto 2008): head-back + expanded → **high-dominance/expansion display** (the felt word "pride" only as a hedged gloss); head-down + head-turned-away → **withdrawal/submission on the dominance axis** ("shame" only as a hedged gloss — and note we read **head-orientation, not gaze**, so this stays hedged). Head-motion energy → arousal/engagement (continuous scalar).
- **Science caveats (design-critical):** **(1) pitch is gaze-gated and non-monotonic** — head-down = shame *only with averted gaze*; with *direct* gaze the same tilt spoofs a V-brow illusion reading **angrier/more dominant** (Witkower & Tracy 2019 *Psych Science*; 2020 *Emotion* — the "AU4 imposter"). **(2)** Lateral tilt (roll) is the **most over-claimed** cue — sign-unstable, smile/gender-confounded (Otta 1994; Torrance 2020) → **low-confidence dimensional only, no dictionary**. Nod/shake: affective *tone* reliable, propositional meaning culture-coded (waggle inverts in India/Bulgaria/Greece) → labels low-confidence.
- **Hard prerequisite:** the **AU4 pitch-correction** must run before any brow/anger read (§4.2, ladder step 0).

### 3.5 VOICE lens (new — arousal channel only; gated on K6)
- **Raw:** mic level + a rolling prosody trace.
- **Features:** F0 mean/variance, intensity, tempo (DIY vDSP/YIN — Apple exposes none); SoundAnalysis laughter/cry events.
- **Interpretation:** **arousal ONLY.** Juslin & Laukka 2003 (*Psych Bulletin* 129:770): arousal robustly in F0 mean/variance, intensity, tempo; **valence markedly inconsistent** → route prosody into the arousal meter, **never** discrete emotion or valence. A laughter event powers Corroborated-Positivity (F6); voice VAD (`SpeechDetector`) **gates speech-driven blinks** so the blink→arousal read stays honest.
- **Availability:** foreground-only; `.unavailable` when mic denied or app backgrounded.

### 3.6 INTERACTION lens (new — zero-permission, fully windowed)
- **Raw:** `SpatialEventCollection.Event` stream (pinch/tap phases incl. **cancelled**).
- **Features:** cancel/correction rate, response latency, input tempo — all deltas from a per-user interaction baseline.
- **Interpretation:** **effort / engagement / frustration** (an orthogonal behavioral load axis). This is the cheapest new lens (no sensor, no permission) and the enabler of **F7 Frustration** — a fully-windowed fusion flagship (co-flagship with F1; its signal density is *use-dependent* and can starve in passive viewing — §4.2).
- **Science:** interaction dynamics + Chua 2024 load features; Doherty-Sneddon & Phelps 2005 (effort ≠ affect — say "effort/load," never "stress").

### 3.7 CONTEXT lens (new — a modifier, not a display)
- Thermal state (drives the sensing governor, §8.5), session duration (feeds fatigue accrual), time-of-day, ambient audio RMS, `DeviceFitStatus`. Not a standalone user-facing lens; it **widens or narrows other lenses' uncertainty** and schedules compute.

---

## 4. The combination framework

**Core thesis (convergent across affect-science + hmd-prior-art + fusion-methods + combination-matrix):** single channels are weak; **leverage lives in COMBINATION + TIME.** Constructs that are *only* measurable by fusion are the greater-than-sum modes — each shipped with its named confound visible as the uncertainty story, and each declaring a **windowed MVV + immersive-enhanced tier** because availability is bimodal.

### 4.1 The combination matrix (bimodal partition — this, not the science, is the binding constraint)
**Always-windowed pairs (ship as the core product):**
| Pair | Fused construct | Note / confound |
|---|---|---|
| Face × Eyes | composure-under-load / focused-attention / fatigue-onset | blink ambiguous → needs a 3rd cue |
| Face × Voice | face-voice congruence; voice **fills the arousal the face lacks** (CCC .264) | Juslin & Laukka; de Gelder |
| Face × Interaction | **frustration / engagement** | task difficulty independent of affect |
| Eyes × Voice | arousal corroboration; voice-VAD **gates** speech-driven blinks | — |
| Eyes × Interaction | vigilance-decline / flow | — |
| Voice × Interaction | vocal + behavioral arousal | — |

**Immersive-gated pairs (expose when the aura is open):** Face×Hands (composure-under-load + Aviezer valence-tiebreak at peak intensity), Face×Head (dominance/approach + **mandatory AU4 pitch-correction**), Eyes×Head (fatigue: PERCLOS + head-droop), Eyes×Hands (cognitive load), Hands×Head (cleanest combined motion-energy arousal + expansion/withdrawal).

**Deprioritized (bimodal mismatch → rarely co-present):** Hands×Voice, Head×Voice, Hands×Interaction, Head×Interaction.

### 4.2 The flagship fused constructs
Each: **required channels (MVV → enhanced) · science anchor · computation sketch · honest phrasing · failure modes · killer-demo moment.** Grade = honesty defensibility (A best). Channels: F=face, E=eyes, H=hands, Hd=head, V=voice, I=interaction.

**⭐ F1 — Composure-under-load / Channel-Divergence (arousal proxies) (grade A−)** *(formerly "Masked-Affect" — retired: the app detects a divergence of behavioral proxies, not concealment)*
- **Channels:** F×E (MVV) → +H/V. **Anchor:** Gross & Levenson 1993 (*JPSP* 64:970) — expressive suppression → **flat face + blinking↑ + sympathetic activation** (skin-conductance Δ 0.86 vs 0.33 μS, F(1,81)=6.19, p<.05); repl. Gross 1998, Roberts/Levenson/Gross 2008. ⚠️ **The sympathetic Δ is ELECTRODERMAL; this app has NO autonomic channel** (no EDA/HR/pupil — §2.2). It proxies arousal *behaviorally* (blink-rate↑, hand-energy↑, vocal-F0↑), each directionally ambiguous alone. So F1 detects the **DIVERGENCE of behavioral arousal proxies from a calm face** — a proxy-of-a-proxy, NOT validated emotional suppression, and framed as such (never "mechanistically grounded," never "concealment").
- **Computation:** detect near-neutral facial valence WHILE arousal proxies diverge upward — blink-rate delta↑ (+ hand-energy/self-touch↑ and/or vocal F0/intensity↑). A windowed cross-channel divergence on the shared arousal axis (§4.4 congruence engine); hysteretic named state, not a per-frame flip.
- **Honest phrasing:** *"Your Persona face reads calm, but blink-rate and hand energy are elevated — composed but activated; possible regulation. Confidence: moderate."* **NEVER "concealing."**
- **Failure modes:** low-expressers (always-flat face) → false positive; gate with the low-expressive-separability score (§5.4). The 15-Hz boundary keeps this from becoming micro-expression lie-detection (refused, §4.5 #3).
- **Killer demo:** a poker face over restless hands → the congruence ring widens + the insight feed narrates "composed but activated." *The whole exceeds the sum.*

**⭐ F4 — Frown + Head-down disambiguation (THE MOTIVATING WORKED EXAMPLE, established)**
- **Channels:** F×Hd×E. **Anchor:** Witkower & Tracy 2019/2020; Harmon-Jones & Allen 1998.
- **Computation — the narrowing ladder (the reusable UX template, §6.6):** **Step 0 PITCH-CORRECT** (strip the geometric AU4 the head-down tilt fakes) → **Step 1 brow morphology** (AU1+15 oblique = sadness lean; AU4+5/7 = anger lean; AU4-alone = effort lean) → **Step 2 motivational direction** (high-motor/approach = anger vs low-motor/collapse/withdrawal = sad/shame — §4.3) → **Step 3 coarse HEAD-ORIENTATION proxy** (head yaw/pitch toward content vs. down-and-away — a *head-direction* proxy, since **the app cannot read gaze or its target** (§2.2): immersive 6DoF yaw, or coarse windowed `VNFaceObservation` yaw. ⚠️ Without gaze the **concentration-vs-shame split is LOW-CONFIDENCE and may stay unresolved** — widen the ladder here, never assert) → **Step 4 blink/load** → **Step 5 time-on-task/interaction-friction.**
- **Honest phrasing (ship this exact ladder):** L0 *"Brow looks lowered, but your head is down — correcting for that"* (**NEVER "angry"**) → L1 *"Lowered brow: effort, displeasure or dejection — ambiguous"* → L2 *"leans [dejection-withdrawal / anger-approach]"* → L3 *"head oriented toward your content → leans focused effort; head turned down-and-away → leans withdrawal — **low confidence, we can't see your gaze, may stay unresolved.**"* Always show the confound being ruled out + an epistemic-confidence meter separate from intensity.
- **Failure modes:** the AU4 pitch imposter if step 0 is skipped (correct FIRST); windowed pitch fidelity (K3).
- **Killer demo:** look down at your lap → the reading does **not** flip to anger; the ladder card shows "correcting for head-down."

**F2 — Cognitive Load / Effort (orthogonal axis, NOT an emotion, grade A−, priority)**
- **Channels:** E×I (MVV) → +H/Hd. **Anchor:** Chua 2024; HP Omnicept (a shipped mean+variance load meter); Doherty-Sneddon & Phelps 2005.
- **Computation:** hand-tension↑ + self-touch↑ + gesture-speed↓ + head-stillness↑ + blink-suppression + slower/corrected interaction → one calibrated 0–1 load meter with variance. **Phrasing:** *"Steady hands, suppressed blinks, slower input — high effort/load (an attention axis, not an emotion)."* **Never "stress."** Failure: anxiety vs task difficulty are indistinguishable → say "effort/load."

**F3 — Fatigue ⇄ Engagement (ONE coupled meter, flips on the blink sign, established)**
- **Channels:** E over time (MVV) → +Hd. **Anchor:** Wierwille 1994 / Dinges PERCLOS (3 SD over baseline); Maffei 2018; engagement multimodal (PMC9911959, arXiv 2403.17175).
- **Computation:** *engaged* = blink-suppress + head/gaze stable + illustrator-rate↑; *fatigued* = blink↑ + long closures (AU43/PERCLOS) + head-droop + motion-energy decay, **accruing over session time**. **Never two meters** — one coupled axis. Phrasing: *"Blinks and closures rising over 22 min with head drooping — alertness declining; consider a break."* Failure: boredom/low-arousal.

**F7 — Frustration (task friction, grade B+, EARLY, zero-permission, fully windowed)**
- **Channels:** F×I (MVV) → +Hd/V. **Anchor:** interaction dynamics + Chua 2024.
- **Computation:** negative/AU4 face + cancel/correction-rate↑ + response-latency↑ (+ self-touch/vocal tension when available). **Killer property:** needs **no new sensor or permission** → a fully-windowed fusion flagship. **Interaction surface (THIS app):** F7's signal comes from manipulation of the app's OWN cancellable/correctable controls — lens-card pinches, the Lab-Mode replay scrubber, detachable-volume drags, calibration flows, toggle churn (`SpatialEventCollection.Event` phases incl. `.cancelled`). ⚠️ **Signal-density caveat:** in PASSIVE viewing (just watching lenses/the aura) there is little manipulation to derive a rate from → F7 correctly reports **low-confidence / `.unavailable`** (a designed state, never a fabricated read). Because that density is use-dependent, the launch **UX proving-ground is F7 ∥ F1** — F1 (F×E) carries a *continuous* signal that never starves and is the fallback proving-ground if on-device use is mostly passive. Failure: distinct from sadness (the interaction signal disambiguates).

**F6 — Corroborated Positivity (the ONLY honest neighbour of "genuine smile," grade B)**
- **Channels:** F×H×Hd×V. **Anchor:** Girard 2021 (AU6 = intensity artifact); a SoundAnalysis **laughter event** is the key.
- **Computation:** positive facial valence co-occurring with head-motion↑ + gesture-rate↑ + a laughter event. Phrasing: *"echoed / not echoed across channels,"* **NEVER "genuine/fake."** This is the *replacement* for the refused genuine-vs-fake-smile feature. Failure: social smiles can be high-arousal too.

**Immersive-gated, lower-priority:** **F8 Dominance** (Hd×H, gated on pitch-correction), **F9 Expansive / High-Dominance Display** (Hd×H×F — an *expansion-posture display on the DOMINANCE axis*, NOT the discrete felt-emotion "pride"; labelled "head-only, we can't see your torso"; "pride" only as a hedged gloss; low base-rate), **F10 Approach/Withdrawal** (Hd×H — the anger-vs-sadness tie-breaker, §4.3), **F5 Covert/Suppressed Arousal** (E×(H/Hd/V) — arousal-specific sibling of F1). **GATED to a stretch tier (need ≥30–60 Hz):** embarrassment/shame/pride **ordered sequences** (Keltner 1995), blink dynamics (100–400 ms), Scherer appraisal-order trajectories.

**The strongest triples (build the L3 rule layer around these six as hysteretic named constructs — NOT learned models):** T1 F×E×(H|V)=composure-under-load; T2 E×Hd×H=fatigue; T3 E×H×I=cognitive-load; T4 F×Hd×E=frown+head-down; T5 F×V×Hd=congruence triangulation (valence+arousal+dominance); T6 F×H×Hd=approach/withdrawal + Aviezer valence-break.

### 4.3 New fusion primitive — motivational DIRECTION (approach/withdrawal)
A genuinely new cross-cutting axis, **dissociable from valence** (Harmon-Jones & Allen 1998; Carver & Harmon-Jones 2009): **anger is negative-valence but APPROACH-motivated**; sadness/shame are **WITHDRAWAL**. Sensable mapping: approach = head level/forward + HIGH motor + expansive; withdrawal = head-down/away + LOW motor + collapse. When the face reads "negative" but can't say *which*, **motor-energy + head-orientation splits anger from sadness** — the branch valence alone cannot make. Underpins F10, F9, and step 2 of the F4 ladder.

### 4.4 The congruence / incongruence engine (agreement as a first-class computed scalar — the literal "greater than the sum")
Make channel agreement a **computed scalar**: consensus **tightens** confidence + raises intensity; divergence becomes a **NAMED** state, **never averaged away**. Ship, in cost order:
1. **Reliability-weighted SIGN/GRADIENT consensus** on the shared arousal axis (each channel emits `a_k∈[−1,1]` with reliability `r_k`; do the signs agree?). Cheapest, most interpretable. **SHIP FIRST.**
2. **Windowed SYNCHRONY** — cosine similarity of channel feature trajectories over a sliding window; a **covariation drop = a divergence EVENT** (DeCon PMC4016122; UVS/CIAS MDPI 2025 10(3):88). This is the *"your channels just diverged"* event that wakes the narrator (composes with BOCPD).
3. Adopt the **Dempster-Shafer / TMC conflict-mass `K` REPRESENTATION** (belief + uncertainty mass + conflict mass; Han 2021) to *surface* disagreement — **without** Dempster's rule (Zadeh pathology; §5 rejected). **InconVAD** (arXiv 2509.20140, 2025) is the fusion *policy*: **selectively integrate only consistent signals** — fuse consensus, quarantine conflict into a named state.
- **Named divergence states:** "composed but activated," "expressive but calm-bodied," "signals conflict — low confidence." **NEVER** average valence across a face-positive/body-negative split (Aviezer 2012: the body wins at peak intensity); **NEVER** call divergence "concealment." Add a **Zadeh-counterexample unit test** in `EmotionSelfTests` if any DS math ships.
- **Dynamic channel weighting (the mechanism, not a mode; research notes §3.4/§4.7):** Aviezer, Trope & Todorov 2012 (*Science* 338:1225) — at PEAK intensity isolated faces are near-chance; the **body discriminates**. So as detected facial intensity/ambiguity rises, **decrease the face's reliability weight `r`, increase motion/head/blink** in the log-pool. This is a principled, one-file replacement for the fixed 0.35 FER+ weight.

### 4.5 THE REFUSED LIST — combinations we deliberately will NOT ship (a PRD feature, not an appendix)
Published in-product as an explicit non-goals surface — a **trust feature** and the pre-emptive answer to "why not detect X?" Each refusal maps to a citation and/or a hardware wall.
1. **Duchenne/AU6 → genuine-vs-fake smile**, even fused (Girard 2021 artifact) → use F6 instead.
2. **Gaze-direction "tells" × anything → deception** (Wiseman 2012 debunk; gaze walled off anyway).
3. **Micro-expression "leakage" × anything** (Porter & ten Brinke 2008: ~2%, don't separate truth/lies; 15 Hz can't sample) — **the boundary that keeps F1 from becoming lie-detection.**
4. **Head-tilt (roll) dictionary × anything** (Otta 1994; Torrance 2020: sign-unstable).
5. **Nod/shake → propositional yes/no/agreement** (McClave 2000, culture-coded).
6. **Pupil × anything** (no API + we refuse to fake it — *say why*).
7. **Power-pose fusion → causal confidence/hormones** (Carney 2016 disavowal; torso unsensable).
8. **Stress / anxiety / depression CLINICAL labels from any fusion** (App Review 5.1.x non-diagnostic).
9. **Self-touch → lying** (DePaulo 2003, d≈.25).
10. **Gesture-emblem dictionary** (crossed-arms=defensive — arms/torso unsensable anyway).

### 4.6 Availability & minimum-viable-version (the graceful-degradation design)
| Construct | Windowed MVV | Immersive-enhanced |
|---|---|---|
| Composure-under-load (F1) | F×E (flat face + blink-climb) | + hands / voice |
| Cognitive-load (F2) | E×I (blink + interaction) | + hands |
| Fatigue (F3) | E over time | + head-droop + motion-decay |
| Frown+head-down (F4) | F×Hd windowed (`VNFaceObservation` pitch-correct + brow morphology + coarse head-yaw) — resolves the false-anger correction + the dejection/anger *lean*; **not** the shame-vs-concentration split (needs gaze — unavailable) | + immersive 6DoF head-down → dominance/withdrawal axis (felt-word "shame" only as a hedged gloss; still gaze-blind) |
| Frustration (F7) | F×I (fully windowed, zero-perm) | + head / voice |
| Corroborated-positivity (F6), Approach/Withdrawal (F10), Expansive/high-dominance display (F9), combined-motion arousal | — | immersive-only (need hands / head-6DoF) |

A fused mode with a dark channel **greys the contribution ghost-dot + widens the fused confidence — never silently drops it or fabricates a value.**

---

## 5. Fusion engine architecture

### 5.1 The chosen design — a 5-layer probabilistic hybrid rule→filter stack (an EXTENSION of `EmotionEngine`, NOT a rewrite)
Each layer is a clean seam onto files that already exist; stage them as independent, individually-shippable increments (the ladder, §8.2).
- **L0 — per-channel feature extraction.** `FaceAnalyzer` (exists, `actor`) + `EyeAnalyzer` / `HandAnalyzer` / `HeadAnalyzer` / `VoiceAnalyzer` / `InteractionAnalyzer` (each an `actor` or `nonisolated final class @unchecked Sendable`, §7.4).
- **L1 — per-channel `CalibratedReading`** `{ probVec | scalar, confidence c_k, availability ∈ {live, degraded, unavailable}, delta-from-baseline }`, published parallel to `reading` (seam c). `OneEuroFilter` (Casiez 2012; 2 params; ~40 lines) denoises each noisy per-channel scalar **here at L1** (smooth at rest, low lag on onsets).
- **L2 — dual-track fusion core** (mirrors what the code already does):
  - **(a) categorical track** — the 8-class face label stays in the existing log-opinion pool (`EmotionDistribution.fused`, `EmotionTypes.swift:171`), but its constant **0.35 weight** (`mlFusionWeight`, `EmotionEngine.swift:49`) **becomes a live per-channel reliability vector** (Aviezer dynamic weighting). Temperature-scale FER+ first (Guo 2017) so the weight means what it says. **Non-face channels NEVER enter this pool** (semantically wrong — seam-a veto); they act only on the dimensional track + as the reliability signal.
  - **(b) dimensional track** — valence/arousal/(dominance/load). **LAUNCH: keep the existing per-axis EMA + generalize only the log-pool weight** (ships immediately). **UPGRADE (gated on a golden-trace A/B): a 4-state Kalman-lite latent filter** whose gain **K = a principled adaptive EMA** and whose innovation **y = a free "surprise" signal**; missing channel = skip update → covariance `P` grows → **the UI widens automatically with zero special-case code**.
- **L3 — crisp hysteretic named-configuration RULES** for the flagship constructs (§4.2) — transparent, unit-tested, **NOT a learned model** (the `EmotionClassifier.Prototype` idiom). Hysteresis reuses the existing `challenger`/`switchMargin`/`switchFrames` pattern.
- **L4 — optional on-device FoundationModels narrator** (§5.6) — narration only, **never source-of-truth**; behind an availability gate + a template-string fallback.

**Wiring:** everything flows through a typed **`AffectEvent` bus** (§5.5) that is simultaneously the UI feed, the golden-trace fixture, and the narrator's input.

**4-state Kalman math (the gated upgrade, for reference):** state `x=[v,a,d,l]ᵀ`; random-walk predict `x⁻=x, P⁻=P+Q`; per channel `k` on observation `z_k`: `y=z_k−H_k x⁻`; `S=H_k P⁻ H_kᵀ+R_k`; `K=P⁻ H_kᵀ S⁻¹`; `x=x⁻+Ky`; `P=(I−K H_k)P⁻`. Observation matrices encode the science: face `H`→v(strong),a(weak); hands→a,l; head→d,a; eyes→a,l; voice→a. `R_k=σ²_k/max(c_k,ε)`. Predict at a fixed 15–30 Hz tick; apply each channel's timestamped observation **asynchronously** so 90–120 Hz hands never block 15 Hz face.

### 5.2 Rejected architecture alternatives (with reasons — see also §11)
- **Deep multimodal transformers** (MulT/MISA/Self-MM/TFN) — **REJECT**: need large aligned labeled corpora + a text modality the app lacks; yield frozen, non-personalized, opaque models; tensor fusion explodes dimensionally (fatal for an N-of-1 on-device app). Borrow only the **cross-modal-attention intuition** as hand-written conditioning (head-down gates the meaning of a frown).
- **Dempster–Shafer as the PRIMARY core** — **REJECT**: Zadeh conflict pathology (can assign near-certainty to a hypothesis both sources deemed unlikely); for 2–5 channels adds complexity without beating the confidence-weighted log-pool. Keep only the *representation* (§4.4).
- **Fuzzy-inference core** — **REJECT**: membership-tuning burden, no gain over crisp hysteresis.
- **Trained EDL/NIG evidential head** — **REJECT** as a source-of-truth: no per-user training data. (The intensity/confidence *concept* — aleatoric/epistemic — is kept; the *trained head* is not.)
- **Growing `EmotionEngine` into the hub** — **REJECT**: bloats the face pipeline with ARKit/audio concerns and risks the face regression. Use a separate `AffectHub` (§7.5).

### 5.3 The AffectEvent stream (the auditable chokepoint — satisfies the "no silent side-channels" ethos)
`struct AffectEvent: Codable, Sendable { id; t; channel; kind; magnitude; confidence; evidence:[SignalRef]; baselineDelta:Double? }`. `EventKind` = {blink, eyeClosureProlonged, selfTouch, gestureBurst, postureShift, headMotionSpike, vocalEvent, **congruenceBreak, arousalConsensus, stateChange(BOCPD)**, calibration*, channelAvailabilityChanged, lowExpresserFlag, baselineRetrack}. `SignalRef` = an enum of **actually-present** signals (au4, blinkRate, selfTouchRate, headPitch, gestureEnergy…) that later **constrains the narrator's citations** (§5.6). Append-only (a ledger ethos): **one type, three consumers** — debug HUD feed, regression fixture, LLM input. `BOCPD .stateShift` (Adams & MacKay 2007; per-user hazard `H`; ~100 Swift lines) fires on the fused V/A stream → drives aura + **wakes the narrator (event-driven, don't poll the LLM)**.

### 5.4 Confidence algebra + BaselineStore
- **intensity = aleatoric** (how strong/ambiguous the expression), **confidence = epistemic** (how much to trust the system) — formalizes the app's existing split.
- **Per-channel confidence:** `c_k(t) = q_cal,k · a_k · recency · q_data,k`, where `q_cal,k`=calibration quality (sample count & spread), `a_k∈{1 live, 0.5 degraded, 0 unavailable}`, `recency=exp(−Δt_k/τ_k)`, `q_data,k`=live quality (landmark confidence × pose penalty; `DeviceFitStatus`). It flows **three ways from one computation**: (1) into the filter as `R_k=σ²_k/max(c_k,ε)`; (2) fused per-axis confidence read off the posterior — **meter half-width ∝ √diag(P)**; (3) the log-pool reliability weight `r_k`.
- **Conformal prediction sets** (split-conformal APS; Angelopoulos & Bates) wrap the label → *"likely {calm, focused}"* when ambiguous instead of a false top-1. Temperature-scale FER+ first. The 36-sample calibration session labels only NEUTRAL → the **non-neutral conformal set comes from ESM→HKStateOfMind** (§5.7).
- **`BaselineStore` (⚡ TENSION-D resolved):** **keep the app's naive subtract-the-neutral** for AU/feature deltas (adequate, zero training data). **Do NOT** adopt the learned Calibrating-Siamese-Network now (Feng & de Sa 2024 — marginal N-of-1 gain vs. complexity + App-Review surface). **Mitigate** the known naive-subtraction failure instead: Kargarandehkordi 2023 — personalization under-performs for **low-expressers** → compute a per-user **"expressive separability" score from the calibration MAD spread** and, when low, **widen all confidences** (larger `R_k`, wider conformal sets, more hedged narration). Generalize `NeutralBaseline` (`ActionUnits.swift:174-193`) into a `BaselineStore: Codable` keyed by channel, each holding **median + MAD** (robust z `=(x−median)/(1.4826·mad)`; the MAD spread powers the low-expresser detector for free), versioned (`schemaVersion` + `personaFingerprint` invalidates on Persona change). Slow re-tracking reuses the existing 2 s-verified-neutral lerp (alpha 0.02) **per channel** → baselines self-heal against session drift (fatigue drifts blink in minutes).

### 5.5 The `AffectEvent` bus placement
`private(set) var events: [AffectEvent]` on `AffectHub` (mirrors the existing `history`, capped like `historyCap`). This is the single auditable chokepoint — every mechanical or agent behavior emits through it, never a side-channel.

### 5.6 The optional on-device LLM interpreter (FoundationModels narrator) — guardrailed
- **Verified API (visionOS 26):** gate on `SystemLanguageModel.default.availability`; `LanguageModelSession(instructions:)` with the guardrail system prompt; `session.prewarm(promptPrefix:)` **on immersive-space-open to hide first-token latency behind the transition**; generate via `respond(to:generating:options:)` or `streamResponse`; guard `session.isResponding`; cap with `GenerationOptions` (low temperature, small `maximumResponseTokens`); handle the **4096-token combined ceiling (TN3193)** → rebuild session.
- **Output is schema-locked:** `@Generable struct Interpretation { @Guide headline; @Guide hedge; @Guide evidence:[SignalRef]; @Guide confidence:Double }` where `SignalRef` is an enum of **actually-present** signals → **"never invents a channel" is a TYPE guarantee**; `evidence[]` non-empty is a hard gate. Input = a compact digest of `AffectEvent`s + current meters, **NEVER pixels.**
- **Guardrail canon (six rules, encoded 3 redundant ways — schema shape + system-prompt text + deterministic post-filter):** (1) expression-ESTIMATE framing ("your Persona shows…"); (2) per-claim channel attribution via required `evidence:[SignalRef]`; (3) confidence gate — refuse/degrade below threshold; (4) non-judgmental congruence — incongruence is "possible regulation," never concealment; (5) no diagnosis — a post-generation label block-list resets the session on violation; (6) never override the classical meters. **Vocabulary = Semantic Space Theory** (Cowen & Keltner 2017): gradients & blends ("between focused and tense"), never crisp single-label verdicts.
- **Latency: UNVERIFIED (community ~20–40 tok/s 3B → a ~60-token hedge ≈ 2–4 s; no official thermal).** Ship L4 behind the availability gate + a **non-LLM templated fallback**; event-driven (BOCPD) + `isResponding` + ≥15–30 s rate-limit; **commit only AFTER K5** confirms 2–4 s is thermally acceptable on-device.

### 5.7 Record/replay + evaluation harness (evaluation without a lab)
1. **Golden-trace flight recorder** (roll-your-own; **NOT** the private-SPI `ARRecorder`): make `FaceGeometry`/AU-delta/per-channel L1 features/`AffectEvent`s/fused reading all `Codable`; serialize timestamped JSONL — **FEATURES & EVENTS ONLY, never pixels** (privacy- and App-Review-safe by construction). Prerequisite: `EmotionReading` is currently `Sendable` but **NOT `Codable`** (`EmotionTypes.swift:197`) → **add `Codable`** (`FacialMetrics` already is).
2. **Deterministic replay** pushes a trace back through L1→L4 → extends `EmotionSelfTests.runAll()` from unit math to **full-pipeline regression AND parameter studies** (sweep EMA alpha, Kalman Q/R, BOCPD hazard H, log-pool weights, hysteresis margins).
3. **ESM ground truth** — occasional 1-tap in-app self-report writes an `HKStateOfMind` sample (init `init(date:kind:valence:labels:associations:)` verified from headers/binding, visionOS 2+; **WRITE availability on visionOS 26 is a §10 verify-item**). Those user-confirmed labels become BOTH the inference-vs-report cross-check AND the **non-neutral conformal calibration set**.
4. Valid claims are **relative & personal** ("for THIS user, valence tracks self-report at CCC 0.5, 90% coverage"), never population accuracy; within-subject **temporal** splits (train earlier, test strictly later — Kargarandehkordi 2023).
- **Build the recorder EARLY** — it makes most fusion/smoothing/change-point/narrator logic CI-gradable off-device between rare hardware sessions.

---

## 6. UX spec (grounded in the ux-lenses findings)

**Cross-cutting laws:** *Meaning, not dashboards — but uncertainty always visible.* The app **already has the honest-uncertainty grammar — extend its vocabulary, don't invent one.** Ship "mean + variance" like Omnicept; uncertainty is a first-class meter; explanations are a feature not a footnote; graceful/ambiguous/unavailable states are first-class visual design; write an expression-estimate disclaimer in the spirit of Hume's; market-safe register ("not diagnostic… self-awareness tool") + a crisis affordance. **Anti-pattern: never gamify an affect readout** (Muse's birds/points) — the aura reflects, never scores.

### 6.1 Channel lens (the 3-strata `ChannelLensView<Raw, Features, Interpretation>`)
Raw stream (collapsible) → derived-feature meters (the `AUMetersView` LazyVGrid `ProgressView` idiom) → calibrated interpretation (1–2 low-dim meters + confidence band + ambiguity label + a persistent "what this can/can't tell you"). Lenses are `Lens`-enum cases (Face/Eyes/Hands/Head/Voice/Interaction).

### 6.2 The fusion dashboard — circumplex + ghost dots + the congruence RING
Extend the existing `ValenceArousalPadView` (Canvas circumplex + fading trail, `ValenceArousalPadView.swift:28-48`): overlay each channel's independent (v,a) vote as a small colored **GHOST dot** (face=its emotion hue; hands/eyes=arousal markers; head=dominance dial), draw the **FUSED** result as the solid glowing dot, with a **faint pull-line** from each ghost to the fused dot — literally "hands say aroused, face says calm, fused lands between with a widened halo." **Contribution weights = the log-pool's live `r_k`, so the viz doubles as an audit of the fusion math.** THE fusion primitive is a **CONGRUENCE RING** around the hero readout: tightens + brightens on agreement, widens + desaturates (VSUP) on conflict → surfaces the named moment ("Composed but activated…"). *The single most novel, most defensible fusion UX.*

### 6.3 The insight feed — narrated `AffectEvent`s
Extend `EmotionTimelineView` (Canvas colored ticks) into a scrolling **INSIGHT FEED**: each entry a timestamped plain-language `AffectEvent`. BOCPD fires the entry ("your state shifted ~30 s ago" as a probability); the FM `@Generable` narrator writes the sentence (schema-locked, confidence-gated, per-claim attribution, Semantic-Space vocabulary). Each entry tappable → expands to the disambiguation ladder (§6.6). Look-to-Scroll (WWDC25 s303) makes it gaze-browsable. **Ship a template-string fallback narrator first** (FM latency is the K5 keystone).

### 6.4 Aura mapping (an honest ambient fused display)
Re-map `ImmersiveView`'s aura (currently face-intensity-driven: `strength = reading.intensity * min(1, reading.confidence*1.6)`, `ImmersiveView.swift:38-47`) to the FUSED reading, uncertainty encoded so it can't overclaim: **HUE = valence** (Apple State-of-Mind purple→blue→orange ramp, for cross-app coherence); **PULSE rate/size = combined arousal** (gesture + blink + head-motion energy); **OPACITY/SHARPNESS = confidence** (low → dim, soft-edged glow — blurry = honestly unsure, the ambient analog of VSUP). BOCPD "state shifted" events drive aura transitions. **Default stays current face-driven behavior (toggleable).** Never a reward loop.

### 6.5 Uncertainty-display patterns (reuse the native grammar; add only VSUP + dotplot)
The app already renders uncertainty three ways: (1) `EmotionHeroView`'s confidence **RING** (`.trim(from:0, to: reading.confidence)`, `EmotionHeroView.swift:23`) vs the separate intensity **GAUGE** (`:86-101`) = epistemic-vs-aleatoric made visual — **give every calibrated meter this pairing**; (2) `EmotionBarsView`'s "bar + thin intensity underline" generalizes to "point estimate + confidence **BAND**" that widens as `r_k` drops; (3) borrow the ONE technique the app lacks — **VSUP** (Correll, Moritz & Heer 2018, CHI): **desaturate + coarsen** a meter's color as confidence falls. For the genuinely-wide **arousal axis** (CCC 0.264): render as a **quantile dotplot** (Kay/Hullman 2016) — ~10–20 stacked dots spanning the plausible range, not a single glowing dot. **Ambiguous signs = a FORKED/split-label meter** (one bar splitting into two labeled prongs); conformal "likely {calm, focused}" = a multi-label chip.

### 6.6 The disambiguation-ladder card (the worked example as reusable UX)
`DisambiguationLadderView`: a **progressive-narrowing stepper** where each resolved step lights up and the **ruled-out confound greys with a strikethrough**, so the user watches the claim narrow in real time (L0 "brow lowered — but head is down, correcting" → L3 "most consistent with focused effort"). **Reused for cognitive-load, engagement-vs-fatigue, and every fusion mode — the single most important honesty widget** (the UI's job is to show the app THINKING, not to assert).

### 6.7 Explanations-as-feature + the honesty-phrasing library (linted)
Each fusion toggle gets an expandable **RationalePanel**: one-paragraph mechanism + the named confound it can't fully rule out + a citation chip + the confidence ceiling. A **linted copy-constants file so no view can overclaim**: "from your Persona" never "your face"; "expression estimate" never "felt emotion"; "possible regulation" never "concealing"; no smiley iconography for negative states; a crisis-resource affordance appears if any negative-affect language surfaces (App Review 5.1.x). **The honesty-phrasing library — every fused readout follows ONE grammar:** `[expression-estimate] + [channel attribution] + [confound being ruled out] + [confidence, separate from intensity]` → encode it as the schema-locked `@Generable` template so every mode's copy is honest by construction.

### 6.8 Spatial architecture, lab mode, onboarding/consent/calibration
- **Home = a lens GRID** (glanceable cards for all enabled channels, tap to focus; grid beats tabs when the goal is to see everything at once). Power users can **detach a channel into its own volumetric window** for side-by-side Lab Mode. Capture/record + calibration live in a **gaze-reactive glass ORNAMENT** (appears on gaze, fades on look-away). Use system HOVER effects on lens cards — **privacy-safe: the system composites the effect on gaze WITHOUT reporting gaze to the app** (the honesty bar's gift). IMMERSIVE = hands/head-6DoF capture + the aura; WINDOWED = face/eyes/voice/interaction + all dashboards.
- **Lab Mode (the developer's on-device iteration + honest self-eval):** (1) side-by-side channel columns (raw+derived+interpreted per channel, detachable) for spotting congruence/conflict live; (2) a live event log (raw `AffectEvent` stream + BOCPD firings + per-channel `r_k` = the fusion audit); (3) a **replay scrubber** over recorded golden-trace JSONL through classifier→smoother→fusion→narrator — **the same file that IS the CI fixture**; (4) an **A/B fusion toggle** (run two strategies — fixed-0.35 vs Aviezer dynamic weighting — on the same replay and diff). Ground-truth overlay: HKStateOfMind self-reports vs inferred valence (per-user CCC, never population). *This lets the developer resolve the §10 smoother/weighting/baseline decisions with recorded on-device sessions instead of literature.*
- **Onboarding/consent/calibration:** each new permission (`NSHandsTrackingUsageDescription`; `NSMicrophoneUsageDescription`; `NSWorldSensingUsageDescription` **only if plane/scene/light context ships** — NOT for head-pose; HealthKit) gets a **purpose-first consent sheet shown ONLY when its channel is first activated**, explaining the on-device-only guarantee (the App-Review moat). **Calibration cost is additive and must be managed** (chaining six ~3-min rituals = ~15–20 min, an adoption-friction wall). Mitigate by **sharing ONE Persona session across the Persona-feed channels**: FACE + EYES (resting blink baseline) + windowed HEAD-pose (neutral pose) all ride the SAME 36-sample neutral-Persona ritual → **one ~3-min session, not three**. Separate rituals only for HANDS (immersive: resting + emteq-style max-intensity, ~2–3 min) and VOICE (a short neutral/quiet sample, ~1 min); INTERACTION accrues its baseline passively from first use (no ritual). **Realistic budget: ~3 min to a useful WINDOWED app after the first shared ritual; +~3 min hands the first time the immersive space opens; +~1 min voice if enabled — progressive and per-channel-on-activation, NEVER a 15–20 min upfront wall.** Reuses the `CalibrationOverlay` ritual (dimmed + progress ring). A **distinct session-recording indicator** (separate from the OS green dot) whenever golden-trace logging is on, with a clear stop. HKStateOfMind 1-tap valence write doubles as ground truth AND the honest export path.
- **Availability/unavailable/ambiguous = three designed lens states**, never an error toast: AVAILABLE (live); UNAVAILABLE-BUT-ENABLEABLE (greyed + inline CTA — "Hands need the immersive space" + a button that opens it); AMBIGUOUS (the split-label state).

---

## 7. Clean seams & module map (as-is → to-be, with verified file:line)

### 7.1 AS-IS spine (verified 2026-07-11)
*(Names below are as of 2026-07-11. In this repo the camera controller is `CameraFeed` (`App/CameraFeed.swift`), the window content is `App/ContentView.swift`, and the Xcode project is generated by XcodeGen from `project.yml`.)*

`PersonaCaptureController` (`@MainActor @Observable NSObject`, **sole** `AVCaptureSession` owner; delegate hops to MainActor `Task` at ~`:156-159`) → `ImmersiveControlsView` sets `persona.onFrame = { engine.ingest }` (`ImmersiveControlsView.swift:262-264`, **the only ingest**) → `EmotionEngine.ingest` (`EmotionEngine.swift:87`, throttle guard `:89`, `minProcessInterval=1/15` `:47`) spawns `Task` → `actor FaceAnalyzer.analyze` (`VNDetectFaceLandmarksRequest`) → `FaceGeometry.extract` (nonisolated enum) → `Sendable FrameAnalysis` → `EmotionEngine.apply` (MainActor). **Isolation:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (project build settings; now `project.yml`); one `actor FaceAnalyzer`; one `nonisolated final class CoreMLEmotionScorer: @unchecked Sendable`; pure math (Emotion, EmotionDistribution, AUComputer, EmotionClassifier, TemporalSmoother, FacialMetrics) are nonisolated/Sendable value types. **The producer=`@MainActor @Observable` class + heavy work=`actor` + Sendable output pattern is the ready-made template for every new channel — copy it, don't invent.**

### 7.2 The verified seams
- **Seam (c) — parallel published readings** beside `reading` (`EmotionEngine.swift:34-42`, the "Published outputs" block): add independent `EyeReading`/`HandReading`/`HeadReading`/`VoiceReading`/`InteractionReading`. **Lowest risk; recommended start per channel.**
- **Seam (b) — blend into the shared V/A** at `EmotionEngine.swift:221` (`let va = smoothedDist.valenceArousal`) — where fusion modes live. ⚠️ **A SECOND identical V/A site exists at `:124` (the no-face branch, `let va = dist.valenceArousal`); any fusion combine must patch BOTH or the no-face path diverges.**
- **Seam (a) — the 8-class log-linear pool** (`EmotionDistribution.fused(with:weight:)`, `EmotionTypes.swift:171` — verified a log-linear product-of-experts). **AVOID pushing hands/eyes/head/voice here** (dimensional, not categorical — the one place all lanes agree). Instead **generalize its weight**: the `0.35` const is `mlFusionWeight` at `EmotionEngine.swift:49` → swap the constant for the live reliability vector.
- **Pitch-correction (ladder step 0):** pitch is **produced at `FaceGeometry.swift:237`** (`pitch: observation.pitch?.doubleValue`), carried in the `Extraction`, but `AUComputer.compute` (`ActionUnits.swift:97`) takes only `metrics + baseline` and AU4 is computed at `:119-122` with pitch **thrown away**. Fix = thread `extraction.pitch` into `compute` (add an optional `pitch=nil` param → today's behavior when nil) and subtract the pitch-induced brow-lower from AU4. **One-param thread, no new plumbing** — but the *magnitude* of the pitch→AU4 offset needs on-device tuning against real Persona foreshortening (gated on K3/K4); the plumbing is trivial, the correction FUNCTION is not.
- **Blink:** reads existing `eyeOpenLeft/Right` (`FaceGeometry.swift:189-190`, consumed `ActionUnits.swift:109`) — no FaceGeometry change; optionally add AU43/AU45 + classifier prototypes + a self-test.
- **Camera ownership:** `ImmersiveControlsView` is the **WINDOW** content — camera + face pipeline are window-owned; the mixed ImmersiveSpace hosts only the aura, reading `appModel.emotionEngine.reading` (`ImmersiveView.swift:38-47`). Matches "only the window owns the camera." The legacy **`VisionExpressionController`** (not part of this repo) had an EAR/blink detector to **harvest for the eyes lens** — and `gazeLeft/Right/Up/Down` booleans that **violate the honesty bar → retire them**.

### 7.3 Engine composition decision — `AffectHub` (the zero-regression spine)
- **`ChannelReading`** — `nonisolated struct …: Sendable, Codable` with `channel` (enum), `date`, `availability` (.live/.degraded/.unavailable), `quality`, optional `valence/arousal: Meter?`, `intensity`, `features:[FeatureKey:Double]`, and `posterior: EmotionDistribution?` **populated ONLY by face**. `Meter={value; confidence}` generalizes the app's intensity-vs-confidence split verbatim. `EmotionReading` **projects into** `ChannelReading(channel:.face)` rather than being replaced.
- **`AffectChannel`** — an OUTPUT protocol (`{ id; latest: ChannelReading; isEnabled; reset() }`), no associated input type (inputs are heterogeneous). Each concrete channel = a `@MainActor @Observable final class` owning its actor analyzer. `FaceChannel` = today's `EmotionEngine` + `extension EmotionEngine: AffectChannel` (~4 lines).
- **`AffectHub`** (recommended OVER growing `EmotionEngine`) — `@MainActor @Observable final class AffectHub { let face: EmotionEngine; var eyes/hands/head/voice/interaction; private(set) var fusion; private(set) var events:[AffectEvent] }`. `AppModel.emotionEngine` (`AppModel.swift:24`) → `affectHub` (keep a `.face` alias for zero-diff consumers). **Zero-regression is STRUCTURAL:** with nothing else enabled, `AffectHub.fusion == face.reading` projected — byte-identical; an empty hub IS the current app.
- **Registry:** extend the existing `Demo` enum (`ImmersiveControlsView.swift:15-21`, a `CaseIterable` registry-driven tab bar) → `enum Lens: String, CaseIterable` + a `FusionRegistry` with `requires: Set<Channel>`, `isAvailable(hub)->Bool`, `@ViewBuilder view(hub:)`; render greyed when `!isAvailable`. Settings via `@AppStorage("lens.<id>.enabled")` / `@AppStorage("fusion.<id>.enabled")` (default false except face). **"Each channel independently enableable" + "grey out honestly" are both direct extensions of shipped UI** — but this is the UI SHELL only. ⚠️ **Capture is NOT a byte-identical enum swap:** the app is single-active-demo today — the camera controller (then `PersonaCaptureController`) has ONE `onFrame` closure that `startSelectedDemo` sets and `stopCurrentDemo` NILs on switch (verified `ImmersiveControlsView.swift` `startSelectedDemo`/`stopCurrentDemo` + `EmotionEngine.swift:262-264`), so only ONE consumer runs at a time. A lens GRID where face + a standalone eye analyzer (+ any raw-frame consumer) run CONCURRENTLY requires re-architecting that single consumer into a **frame/feature fan-out distributor** (US-B5a) — a real structural change, distinct from the `AffectHub` "empty hub == today" claim (which holds only while nothing else is enabled).
- **`FusionMode` protocol:** `Sendable { id; title; requires: Set<Channel>; rationale: String; func fuse(...) -> FusionOutput }` — each named construct is an off-by-default value strategy in a `FusionRegistry`; `rationale` is the shown "why." `DynamicChannelWeighting` plugs at seam B; with one channel it is the **identity** (face-only unchanged).

### 7.4 Concurrency & plist (the gotcha list — first-class, not afterthoughts)
1. **MainActor default** — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means any unmarked new type silently hops to main. Two proven off-main shapes: `actor XAnalyzer` (FaceAnalyzer idiom) or `nonisolated final class X: @unchecked Sendable` on a private queue (CoreMLEmotionScorer idiom). Every value crossing the hop = `nonisolated struct …: Sendable, Codable`. HandsChannel=`actor HandAnalyzer` on `HandTrackingProvider.anchorUpdates`; VoiceChannel=`actor VoiceAnalyzer` on an `AVAudioEngine` tap + SoundAnalysis.
2. **Project sync & plist** (in the original Xcode project, `objectVersion=77` with `PBXFileSystemSynchronizedRootGroup`, new `.swift` files auto-added to the target, frameworks auto-linked on import (ARKit/SoundAnalysis/Speech needed no build-phase edit), entitlements/capabilities went through Xcode, and Info.plist was a direct edit; this repo generates the project with XcodeGen from `project.yml`). Add `NSHandsTrackingUsageDescription` (hands). `NSWorldSensingUsageDescription` is **only** for immersive room/plane/light CONTEXT signals (scene reconstruction / plane detection / light estimation) — it is **NOT** required for head-6DoF, whose `WorldTrackingProvider.queryDeviceAnchor` device-anchor is prompt-free once the provider runs (auth rides the ARKit hand-tracking request already made at immersive-open); **omit it entirely if no plane/scene/light features ship.** And (if voice greenlit) `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`; HealthKit needs `NSHealthShare/UpdateUsageDescription` + a separate entitlement. **Note: the current `NSMainCameraUsageDescription` is the enterprise key — a red herring; the consumer front-camera path uses `NSCameraUsageDescription`.**
3. **~15 Hz throttle** (`minProcessInterval=1/15`): blink-RATE-over-window survives undersampling; Keltner-onset SEQUENCE detectors may be infeasible → GATED on confirmed Hz (K2).
4. **Capture contention:** FaceTime pre-empts `systemPreferredCamera` → keep `FaceChannel` the sole KVO owner + graceful pre-emption.
5. **Full-space-only coupling:** hands/head flow ONLY when the aura ImmersiveSpace is open → declare `requires` + grey out, never fake. An `ImmersiveSensingCoordinator` created in `ImmersiveView.onAppear` (which already flips `appModel.immersiveSpaceState`) runs `ARKitSession` + `HandTrackingProvider` + `WorldTrackingProvider`, pushing into `AffectHub`; on close, channels flip to `.unavailable`.
6. **Authorization** lives in `enum Permissions` (`@MainActor`; the camera check is now `cameraAccess()`) — extend with `requestMicIfNeeded()` + `requestHealthIfNeeded()`. ARKit HandTracking/WorldTracking auth is requested via `ARKitSession.requestAuthorization(for:)` **at immersive-space open**, not in `Permissions`; surface its grant state through `Permissions` for one status view.

---

## 8. Phased roadmap

**Verification idiom (this repo):** `build_sim` green (scheme "AffectLens", Apple Vision Pro simulator) + `EmotionSelfTests.runAll()` extended for **all new pure math** (traps at launch on regression) + **on-device behavior checks by the developer**. **NO simulator E2E.**

### 8.0 Phase 0 — KEYSTONE prove-or-kill spikes FIRST (each with an explicit gate)
Nothing downstream builds until its keystone passes. Each is a smallest-possible on-device measurement.
| # | Keystone | Smallest test | GATE (pass → / fail →) |
|---|---|---|---|
| **K1** | **HandTracking ↔ Persona-camera coexistence** (research notes §8.9; the load-bearing unknown for ALL face+hands fusion) | Open the aura + run `HandTrackingProvider`; watch `EmotionEngine.processedFPS` (shown `EmotionDashboardView.swift:115`) | face pipeline stays ~15 Hz & reading intact → hands+face fusion proceeds · else hands stays immersive-isolated or is cut |
| **K2** | **Blink recoverability at ~15 Hz** | Rolling blinks/min HUD off `eyeOpenLeft/Right`; forced arousal (breath-hold / mental math) vs calm | blink rate rises legibly & blinks register → eyes lens + F1/F3 proceed · else raise eye-path throttle or cut the eye channel |
| **K3** | **Windowed Persona-pitch fidelity for AU4 correction** (CONFLICT-A) | HUD `VNFaceObservation.pitch`; look down at lap; does pitch track enough to drive AU4 correction? | reliable → F4 windowed MVV + all windowed head reads proceed · directional-only → gate head-down dominance/withdrawal (shame only as a hedged gloss) to immersive |
| **K4** | **Persona expression bandwidth for subtle AUs** (the foundational "face = Persona, not face" truth) | Compare subtle AU deltas (small frown, slight squint) against felt expression at the capture framing | adequate → all face-derived constructs valid · poor → widen all AU uncertainty globally, lower the confidence ceiling |
| **K5** | **FoundationModels latency/thermal** (gates the L4 narrator) | Time `respond(to:generating:)` for a ~2–3k-token `AffectEvent` digest on-device; watch `thermalState` over a session | ≤~2–4 s & thermally sustainable → FM narrator ships · else template-string narrator only |
| **K6** | **Mic ↔ camera coexistence + prosody legibility** (gates the voice channel) | `AVAudioEngine` tap alongside the running `AVCaptureSession`; DIY vDSP F0/intensity HUD; does arousal separate speaking-excited vs calm? | coexists & legible → voice channel + Face×Voice ship · else voice cut |

### 8.1 Phase sequence (session-sized user stories, each with acceptance criteria)
Follows the **11-step evolution ladder** (research notes §8.10) — steps 0–4 are pure additive/refactor with **byte-identical face output**; net-new sensing only starts once the abstraction is proven regression-free.

**Phase A — the bug + the zero-regression spine (no new sensing):**
- **US-A0 · Pitch-fix (ladder 0).** Thread `extraction.pitch` into `AUComputer.compute` (`ActionUnits.swift:97`, optional `pitch=nil`); discount the pitch-induced brow-lower from AU4 (`:119-122`). AC: `EmotionSelfTests.pitchCorrection()` — synthetic down-pitch + neutral brow must **not** classify anger; `build_sim` green; on-device, looking down no longer flips to anger. **Ships alone (code-independent — no other US depends on it).** ⚠️ But the pitch→AU4 offset FUNCTION (how much AU4 to subtract per unit pitch) is **empirical and needs an on-device tuning pass gated by K3 (windowed-pitch fidelity)/K4** — the synthetic `pitchCorrection()` self-test passes regardless of the real-world bug magnitude, so green CI ≠ validated correction.
- **US-A1 · `ChannelReading`+`Meter`+`Codable` on `EmotionReading`** (`EmotionTypes.swift:197`); project face→`ChannelReading`. AC: identical face output; self-tests pass.
- **US-A2 · `extension EmotionEngine: AffectChannel`.** AC: ~4-line diff; no behavior change.
- **US-A3 · `AffectHub` holding only `let face`;** `AppModel.emotionEngine → affectHub.face` alias; rewire aura + dashboard through the hub. AC: **byte-identical output**; `build_sim` green.
- **US-A4 · `BaselineStore`** + migrate the v1 face key (`EmotionEngine.NeutralBaseline.v1`, `ActionUnits.swift:174-193`) via a fallback read. AC: `baselineMigration()` self-test — v1 face key still loads.

**Phase B — the first net-new lens + registry + events (windowed, near-free):**
- **US-B5a · Frame/feature distributor (capture fan-out).** Convert the camera controller's single `onFrame` closure (then in `PersonaCaptureController`) into a multiplexed distributor (`addConsumer`/`removeConsumer`) so N windowed analyzers receive each `CMSampleBuffer` (or the shared `FrameAnalysis`) concurrently, and switching lenses no longer NILs the sole consumer. AC: with only the face consumer registered the reading is **byte-identical** to today; a second no-op consumer provably receives frames; enabling Eyes alongside Face runs both without dropping face FPS; `build_sim` green. **Prerequisite for the lens GRID; a real structural change to capture, NOT byte-identical to today's single-consumer shape (§7.3).**
- **US-B5 · Eyes/blink lens** (windowed, off `eyeOpenLeft/Right`; adaptive-EAR). Gated on **K2** (+ US-B5a if run as a standalone analyzer). AC: blink events + blinks/min-delta meter; `blinkRate()` self-test; on-device blink rate rises under forced arousal.
- **US-B6 · Lens/Fusion registries + `@AppStorage` toggles** (all off but face). AC: `fusionModeRegistry()` self-test — every mode has non-empty `requires` + `rationale`; greyed-lens states render.
- **US-B7 · `AffectEvent` bus + BOCPD on face V/A → aura reacts.** AC: events append; a state-shift fires the insight feed; template-string narrator writes the entry.

**Phase C — the first fusion flagships (windowed):**
- **US-C8 · `FusionMode` DynamicChannelWeighting at seam B** (patch BOTH `:124` and `:221`); single-channel = identity. AC: `logPoolWeights()` self-test — an `r=0` channel drops to identity; face-only unchanged.
- **US-C9 · F7 Frustration (F×I, zero-permission)** — a fully-windowed fusion; UX proving-ground alongside F1 (US-C10), measured off the app's own manipulable controls (§4.2; passive-use starvation is a designed low-confidence state). AC: interaction cancel/latency features feed the construct; RationalePanel shows the "why"; on-device a correction-storm surfaces "frustration (task friction)."
- **US-C10 · F1 Composure-under-load MVV (F×E)** + the congruence engine (option 1 sign-consensus + option 2 windowed synchrony) + the congruence RING + the disambiguation-ladder card. AC: `EmotionSelfTests` congruence math; on-device, a poker face over a climbing blink rate → "composed but activated; possible regulation."
- **US-C11 · F3 Fatigue⇄Engagement (E over time)** — one coupled meter. AC: session-time accrual; on-device blink+closure rise over minutes → "alertness declining."

**Phase D — the immersive channels (behind K1) + the voice channel (behind K6):**
- **US-D12 · Voice channel** (windowed mic; SoundAnalysis + DIY vDSP prosody → arousal only). Gated on **K6**. AC: laughter event fires F6 corroboration; prosody feeds arousal, never valence.
- **US-D13 · Hands + Head channels** behind **K1** + F2 Cognitive-Load / F8 Dominance (pitch-corrected). AC: `HandAnalyzer` actor; frustum-robust rate features; on-device wave/rest/face-touch separate legibly.
- **US-D14 · F4 full frown+head-down** (immersive head-down → dominance/withdrawal axis, "shame" only as a hedged gloss; gated on **K3**; still gaze-blind, so the shame-vs-concentration split stays hedged).

**Phase E — the interpreter + the harness (gated on K5):**
- **US-E15 · Golden-trace recorder + replay** feeding `EmotionSelfTests` (the CI fixture format). AC: JSONL features/events only (never pixels); deterministic replay reproduces a fused reading.
- **US-E16 · FoundationModels narrator** behind **K5** + availability gate + template fallback + the 6-rule guardrail (schema + prompt + post-filter). AC: `evidence[]` non-empty enforced; a diagnosis attempt is post-filter-reset.
- **US-E17 · ESM→HKStateOfMind ground-truth loop** + Lab Mode replay/A-B + per-user CCC overlay. AC: 1-tap write; conformal set populated from non-neutral labels.
- **US-E18 · 4-state Kalman-lite upgrade** — **only if** a golden-trace A/B (US-E15) shows it beats the log-pool + per-axis EMA fallback (TENSION-C remaining check). AC: parameter-study replay demonstrates the win before merge.

**Cross-cutting (every phase):** **US-X1 Uncertainty everywhere** (every new meter shows confidence + states ambiguity in plain language); **US-X2 Self-tests** (`EmotionSelfTests` extended for all new pure math, traps at launch). The **thermal governor** (§8.5) lands with the first immersive channel: `.nominal` all on; `.fair` FM off; `.serious` drop FER+ / halve face cadence 15→8 Hz / hands→30 Hz; `.critical` face+baseline only.

---

## 9. Success metrics + risks

### 9.1 Success metrics (per-user & relative, never population accuracy)
- **M1 — Legibility (the keystone gates):** each channel yields a legible on-device signal — blink rate rises under forced arousal; gesture energy separates wave/rest/face-touch; windowed pitch drives AU4 correction (the developer's on-device judgment).
- **M2 — Zero face regression:** `AffectHub` with nothing enabled is byte-identical to today; `build_sim` green; `EmotionSelfTests` pass at every ladder step.
- **M3 — The pitch bug is dead:** the look-down false-anger case is eliminated (`pitchCorrection()` + on-device).
- **M4 — Greater-than-sum is demonstrable:** F1 Composure-under-load surfaces a state (calm face + agitated hands/blink) that **no single lens shows**; F7 Frustration does so with zero new permissions.
- **M5 — Legible fusion:** every fused insight shows contributing channels + confidence (ghost dots + congruence ring); no black box.
- **M6 — Honest per-user accuracy:** where ESM labels exist, inferred valence tracks self-report at a stated per-user CCC + conformal coverage (e.g. "CCC 0.5, 90% coverage for THIS user") — never a population claim.
- **M7 — Narrator honesty:** 100% of narrated insights cite ≥1 present `SignalRef`; 0 felt-emotion or diagnostic strings survive the post-filter.

### 9.2 Risks + mitigations
| Domain | Risk | Mitigation |
|---|---|---|
| **Science** | Cues are probabilistic, person-variable (Barrett 2019); low-expressers' faces stay flat (Kargarandehkordi 2023); face-arousal is weak (CCC .264) | Per-user baselines everywhere; the low-expressive-separability widener (§5.4); arousal shown as a quantile dotplot; reconstruct arousal from motion/voice; refused list as a feature |
| **Platform** | Persona pixels are doubly-removed from muscle action; windowed pitch fidelity unknown; hand/camera coexistence unproven; point-release drift after Jan-2026 cutoff | K1–K4 spikes gate everything; "from your Persona" copy; graceful degradation via covariance; re-verify on 26.1–26.4 |
| **App Review / privacy** | 5.1.x non-diagnostic; camera/HealthKit may not feed ads; Nov-2025 5.1.2 third-party-AI consent | On-device-only (the moat); non-diagnostic copy + crisis affordance; per-channel purpose-first consent; no false HealthKit writes; features/events never pixels |
| **Performance** | Continuous 1080p@30 + Vision + FER+ (+ SoundAnalysis + FM + immersive ARKit) is sustained M2/R1 load on a ~2–2.5 h battery | The `thermalState`-driven sensing governor as a real scheduler (§8.5); FM event-driven + rate-limited + prewarmed; multi-rate async filter so 90–120 Hz hands never block 15 Hz face |
| **Latency (FM)** | ~20–40 tok/s community estimate, no official thermal | K5 gates commit; template-string fallback ships first; `prewarm` hides first-token behind the space transition |

---

## 10. Open questions / decisions (each with a recommendation)

**Scope / product:**
- **OQ1 — Voice in scope?** *Recommend YES, but gated on K6* — highest-ROI missing channel, fully on-device, but depends on unverified mic-camera coexistence + a prosody spike. Sequence it in Phase D, not launch.
- **OQ2 — Interaction-dynamics lens in scope?** *Recommend YES, at launch* — zero-permission, fully windowed, and it enables F7 (the first fusion flagship). Re-scopes v1's "eyes" ambition toward attention/interaction.
- **OQ3 — Which named constructs at launch?** *Recommend:* F7 Frustration + F1 Composure-under-load **as co-proving-grounds** (F7 = zero-perm interaction flagship *when the user is actively manipulating*; F1 = the continuous-signal fallback that never starves in passive use) + F3 Fatigue⇄Engagement + F4 frown+head-down (windowed); defer F2/F6/F8/F9/F10 to Phase D. **Drop genuine-vs-fake-smile → F6 Corroborated-Positivity.**
- **OQ4 — FM narrator now or after K5?** *Recommend: template-string narrator first, FM after K5.* Unbenchmarked latency/thermal; the fallback ships the insight-feed UX regardless.
- **OQ5 — Hands = hands-only vs fused?** *Recommend fused* (the whole exceeds the sum). Accept "hands ⇒ immersive open," reframed as "the aura gains a hand-driven pulse."
- **OQ6 — Focus/effort axis on by default?** *Recommend opt-in, off by default,* labeled low-confidence and orthogonal to emotion. **Verify:** does App Review treat on-device "cognitive load"/"fatigue" as health/diagnostic data even without a HealthKit write?

**Method / architecture:**
- **OQ7 — Fusion dimensional core.** *Recommend: ship the log-pool + per-axis EMA/OneEuroFilter fallback at launch; earn the 4-state Kalman via a golden-trace A/B (US-E18).* Measure-first; don't ship the heavier filter until replay proves it beats the fallback.
- **OQ8 — Congruence math order.** *Recommend:* reliability-weighted arousal sign-consensus (cheap) → windowed cosine-synchrony (DeCon/UVS) → optionally DS/TMC conflict-mass (with a Zadeh unit test). Ship the first two.
- **OQ9 — Keep the `EmotionEngine` name** (+ `AffectChannel` extension) or rename to `FaceChannel`? *Recommend keep* (minimal diff; the `.face` alias absorbs consumers).
- **OQ10 — Fusion combine site:** patch BOTH V/A sites (`:124`, `:221`) inside `EmotionEngine`, or lift V/A into `AffectHub`? *Recommend patch both at launch* (smaller diff), lift later if the per-channel smoothers demand it.

**On-device observations only the developer can make (these ARE the keystones):** K1 hands-coexistence, K2 blink@15Hz, K3 windowed-pitch fidelity, K4 Persona subtle-AU bandwidth, K5 FM latency/thermal, K6 mic-coexistence + prosody. Plus: **does opening the immersive aura (required for hands/head) change natural behavior enough to bias the hand/head baselines captured there?**

**UX:**
- **OQ11 — Home layout:** lens GRID vs focused TAB bar vs detachable volumes? *Recommend a grid home + tab focus + detachable Lab volumes* — needs an on-device try.
- **OQ12 — Aura blur-as-confidence:** honest, or reads as a rendering bug? Arousal quantile-dotplot legibility at a glance? (on-device aesthetic calls.)
- **OQ13 — Color strategy:** discrete-emotion hues for the label AND Apple's State-of-Mind valence ramp for the dimensional axes — or does a dual palette confuse?
- **OQ14 — HKStateOfMind self-report:** when to fire (BOCPD state-shift? session end?) so it's a natural ground-truth loop, not an interruption?

**Legal / verify:** SwiftF0 license + CoreML-convertibility (vs hand-rolled vDSP); HKStateOfMind **WRITE** availability on visionOS 26 specifically + required entitlement; whether App Review treats on-device affect (incl. load/fatigue) as "health data" absent a Health write; point-release drift (26.1–26.4: camera/Persona, hover/gaze, ARKit-provider space rules).

---

## 11. Rejected alternatives (research-informed — what we chose NOT to do, and why)

**Architectures:**
- **Deep multimodal transformers (MulT / MISA / Self-MM / TFN)** — need large aligned labeled corpora + a text modality the app lacks; frozen, non-personalized, opaque; tensor fusion explodes dimensionally — **fatal for an N-of-1 on-device app.** Kept only the cross-modal-attention *intuition* as hand-written conditioning (head-down gates a frown's meaning). *(research notes §4)*
- **Dempster–Shafer as the primary fusion core** — Zadeh conflict pathology; for 2–5 channels no gain over the confidence-weighted log-pool. Kept only the belief/uncertainty/conflict-mass *representation* to surface disagreement. *(research notes §4.2, §10 TENSION-E)*
- **Fuzzy-inference core** — membership-tuning burden, no gain over crisp hysteretic rules.
- **Trained EDL/NIG evidential head as source-of-truth** — no per-user training data; the concept (aleatoric/epistemic) is kept, the trained model is not.
- **Learned Calibrating-Siamese-Network baseline** (Feng & de Sa 2024) — beats naive subtraction on DISFA/BP4D but needs a trained model; marginal N-of-1 gain vs. complexity + App-Review surface. **Deferred**; revisit only if a golden-trace A/B shows subtraction is the bottleneck. *(research notes §4.4, §10 TENSION-D)*
- **The 4-state Kalman as the launch dimensional core** — demoted to a **golden-trace-gated upgrade** (US-E18). Measure-first: ship the simpler log-pool + per-axis EMA/OneEuroFilter fallback until replay proves the Kalman wins.
- **Growing `EmotionEngine` into the hub** — would bloat the face pipeline with ARKit/audio concerns and risk the face regression; use a separate `AffectHub`. *(research notes §8.4)*

**Channels & claims (the refused list, §4.5, is the productized form):**
- Genuine-vs-fake smile (Duchenne/AU6 = intensity artifact); gaze-direction tells (walled off + Wiseman 2012 debunk); micro-expression leakage (the anti-lie-detection boundary); head-tilt/nod dictionaries (sign-unstable/culture-coded); pupillometry (no API — *say why*); power-pose causal claims (Carney 2016 disavowal; torso unsensable); clinical stress/anxiety/depression labels (App Review 5.1.x); self-touch→lying (d≈.25); gesture-emblem dictionary (torso unsensable).
- **Torso/posture via the on-device solo path** — physically unsensable; the only route is a **paired iPhone body-cam** (`ARBodyTrackingConfiguration` streamed over the local network) — a materially bigger architecture + second device. **Explicitly out of scope; kept on the radar as a future maybe.** *(spike §1, §8)*

**Ordered sequence detectors at launch** (embarrassment/pride onset, blink dynamics 100–400 ms, Scherer appraisal-order) — require ≥30–60 Hz; the ~15 Hz pipeline can't sample them. **Scoped to a stretch tier, gated on confirmed Hz** — not a launch blocker (all flagships use rate/energy over a window, which survives undersampling). *(research notes §3.7, §10 CONFLICT-B)*

**Build-vs-buy for the interpreter/oracles:** cloud expression APIs add a network and vendor dependency (and some, such as Affectiva's, have shifted toward other markets) → **on-device-first is the de-risked default, not just privacy-preferred.** Offline-only validation oracles (OpenFace/LibreFace non-commercial; EmoNet/AffectNet research-only + wrong output shape; openSMILE paid) — **never ship**; use for grading AU/V-A mapping off-device only. *(research notes §6)*

---

## 12. Sources (load-bearing only)

**Platform / Apple (min OS in text):** `systemPreferredCamera` + Persona virtual-camera capture (Apple Developer Forums 749810/749613); ARKit-in-visionOS — `HandTrackingProvider`, `WorldTrackingProvider.queryDeviceAnchor`, `HandSkeleton.JointName`, `ARKitSession.requestAuthorization(for:)` (WWDC23 s10082, WWDC24 s10100/s10104, WWDC25 s289); `SpatialEventGesture`/`SpatialEventCollection.Event`; gaze privacy + Look-to-Scroll (WWDC25 s303/s317); Speech/`SpeechDetector` (WWDC25 s277); `SoundAnalysis` `SNClassifySoundRequest` (WWDC21 s10036); `AVAudioApplication.requestRecordPermission`; **`HKStateOfMind`** (WWDC24 s10109 + docs, visionOS 2+); **FoundationModels** `LanguageModelSession`/`@Generable`/`@Guide`/`prewarm`/`isResponding` + **TN3193 (4096-token ceiling)** (WWDC25 s286/s301); `ProcessInfo.thermalState`; App Review Guidelines 5.1.x + 5.1.2 third-party-AI (TechCrunch 2025-11-13).

**Affect science (the construct anchors):** Barrett et al. 2019 (*PSPI* 20:1); **Gross & Levenson 1993 (*JPSP* 64:970)** + Gross 1998 + Roberts/Levenson/Gross 2008 (suppression → flat face + blink↑ + sympathetic); Aviezer/Trope/Todorov 2012 (*Science* 338:1225) + Meeren 2005 + Aviezer 2008 (body breaks valence at peak intensity); **Witkower & Tracy 2019 (*Psych Science* 30:893) / 2020 (*Emotion*)** (head-pitch AU4 imposter); Tracy & Matsumoto 2008 (*PNAS* 105:11655, pride/shame innate); Harmon-Jones & Allen 1998 + Carver & Harmon-Jones 2009 (anger = approach); Doherty-Sneddon & Phelps 2005 (gaze-aversion = load); Girard 2021 + Krumhuber & Manstead 2009 (Duchenne = intensity artifact); Juslin & Laukka 2003 (*Psych Bulletin* 129:770, voice = arousal not valence); Wierwille 1994 / Dinges & Grace 1998 (PERCLOS); Maffei & Angrilli 2018; Chua et al. 2024 (arXiv 2409.12921, Motion-as-Emotion, per-user LOSO collapse); DePaulo et al. 2003 (*Psych Bulletin*, cues-to-deception d≈.25); Wiseman et al. 2012 (*PLOS ONE*, NLP eye-cue debunk); Porter & ten Brinke 2008 (micro-expressions); Keltner 1995 (embarrassment sequence); Du/Tao/Martinez 2014 (*PNAS* 111:E1454, compound expressions); Cowen & Keltner 2017 (*PNAS* 114:E7900, semantic space); Carney 2016 (power-pose disavowal).

**Fusion / uncertainty / eval:** Allognon 2020 (IJCNN, visual-only V 0.516 / A 0.264); Lin 1989 (CCC); Aviezer 2012 (dynamic weighting); Han 2021 ICLR (TMC, `hanmenghan/TMC`) + Zadeh conflict + Yager/Murphy rules; **InconVAD (arXiv 2509.20140, 2025); DeCon (PMC4016122); UVS/CIAS (MDPI 2025 10(3):88)**; Guo 2017 (temperature scaling); Angelopoulos & Bates (split-conformal APS); Adams & MacKay 2007 (BOCPD, arXiv 0710.3742); Casiez 2012 (OneEuroFilter, CHI); Wu 2023 ACL (DEER, aleatoric/epistemic); Tellamekala 2022 (COLD Fusion); Kargarandehkordi 2023 (arXiv 2311.12812, low-expresser personalization); Feng & de Sa 2024 (arXiv 2409.00240, Siamese baseline — deferred).

**HMD prior art & UX precedent:** HP Omnicept (cognitive-load mean+variance meter + open dataset, IEEE VR 2025); emteq OCOsense (Kiprijanovska 2023, max-intensity calibration ritual); Meta Quest Pro Movement SDK (platform withholds emotion labels); Hume AI (expression-estimate honesty template; cloud sunset 2026-06-14); WHOOP 5.0 ("tile is a doorway"); Apple Fitness rings / State-of-Mind valence ramp; Muse (gamification anti-pattern); Correll/Moritz/Heer 2018 (VSUP, CHI); Kay/Kola/Hullman/Munson 2016 (quantile dotplots, "When (ish) is My Bus?", CHI); Noroozi 2018/2023 (body-affect immaturity → no dictionary); face-body incongruence review (Springer 10.1007/s10919-025-00488-x).

**OSS (shippable vs oracle):** HandVector 2.0 `FingerShape` (MIT) + VisionOS-SimHands bridge; OneEuroFilter (Swift, permissive); `dtolpin/bocd` (BOCPD ~100 lines); adaptive-EAR (Soukupová & Čech 2016); Apple FoundationModels + SoundAnalysis (zero-license laughter/cry); FER+ (shippable 8-class expert); MediaPipe Face Landmarker (Apache-2.0, **offline AU oracle only**); OpenFace/LibreFace + EmoNet/AffectNet + openSMILE (**offline validation only — never ship**); DIY vDSP/YIN prosody (shippable); golden-trace flight recorder (roll-your-own; **not** the private-SPI `ARRecorder`).

**Code claims (verified `file:line`, 2026-07-11):** `EmotionEngine.swift` — published `reading` block :34-42, `minProcessInterval=1/15` :47, `mlFusionWeight=0.35` :49, `ingest`+throttle :87-89, no-face V/A :124, main V/A :221 · `EmotionTypes.swift` — `EmotionDistribution.fused(with:weight:)` log-pool :171, `EmotionReading` (Sendable, **not Codable**) :197 · `ActionUnits.swift` — `compute(metrics:baseline:)` :97, `eyeOpenDelta` :109, AU4 :119-122, AU5-7 :124-131, `NeutralBaseline` (+key `EmotionEngine.NeutralBaseline.v1`) :174-193 · `FaceGeometry.swift` — `eyeOpenLeft/Right` :189-190, yaw/roll/pitch :235-237 · `ImmersiveControlsView.swift` — `Demo` enum :15-21, `onFrame=engine.ingest` :262-264 · `ImmersiveView.swift` — aura reads `reading` :38-47 · `AppModel.swift` — `let emotionEngine = EmotionEngine()` :24 · `EmotionHeroView.swift` — confidence ring `.trim` :23, intensity gauge :86-101 · `ValenceArousalPadView.swift` — Canvas circumplex + trail :28-48 · `EmotionSelfTests.swift` — `runAll()` :16 + assert-trap sections :24+ · `EmotionDashboardView.swift` — `processedFPS` shown :115.

---
*PRD v2, 2026-07-11. Evidence base: `docs/design/spike-body-language-gesture.md` and the wave's research notes. This document supersedes PRD v1 and is the buildable contract; keep it and the spike in sync as later waves refine the constructs and resolve the keystones.*
