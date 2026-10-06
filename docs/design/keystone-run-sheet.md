# Keystone Run Sheet — on-device single-session checklist

**App:** AffectLens, developed as Facial Computing (visionOS 26, Apple Vision Pro) · **Scope:** the affect-fusion wave (channel lenses + fused constructs) · **Audience:** the developer, on-device, one sitting.

This is a runnable script. Work top-to-bottom; tick each box; read the **GATE** and do the **on FAIL** action before moving on. It implements the PRD's keystone table (`docs/design/prd-multichannel-affect-sensing-v2.md` §8.0, K1–K6) and success metrics (§9.1, M1–M7). **Every UI label, HUD header, toggle name, and settings key below is verified against the shipped code** — where this sheet quotes a label in `"quotes"`, that is the exact on-screen string.

Behavior is tested on-device by the developer — there is no simulator E2E. Note that **hands, head-6DoF, and voice are device-only** (the simulator has no hand/world-tracking provider and no mic↔camera coexistence). Eyes, interaction, windowed head-pose, and the pitch fix work windowed.

---

## Where things live (navigation map)

- App opens to one **window** with a tab strip: **`Emotion`** (default) · **`Lab`**. *(The original build also carried `Persona`, `Vision` and `Frame` demo tabs; they are not part of this repo.)*
- The **Emotion tab is a lens-grid home** (`EmotionLensHomeView`): a hero strip with the **congruence ring**, a **`Record trace`** control, the ESM **`How do you feel?`** button, the **insight feed**, the **lens grid** (Face · Eyes · Hands · Head · Voice · Interaction cards), the **`Fusion constructs`** section, the **`Ground truth — for you, on this device`** section, and the **`Aura follows fused signals`** toggle.
- **Tap the Face card** to open the **dashboard** (`EmotionDashboardView`). Its control bar has **`Start`/`Stop`**, **`Calibrate Neutral`**, and the **`Science`** toggle. The right column's bottom holds the four **K-HUDs** (collapsible disclosure groups), top-to-bottom:
  1. **`AU4 pitch-correction · head (K3)`** — the K3/K4 panel (+ the head lens).
  2. **`Eyes / blink (K2)`**
  3. **`Voice / prosody (K6)`**
  4. **`Hands (K1)`**
- **Each lens enable toggle appears in two places** — the lens **card footer** on the home grid *and* inside its **K-HUD** — both bound to the same key, so flipping either flips both.
- The **aura** is the optional mixed `ImmersiveSpace`, opened by the **bottom ornament** (`ToggleImmersiveSpaceButton`). Opening it starts ARKit hand + world tracking (K1) and the 6DoF head source.

**Settings keys** (all default **off/identity** — the empty app is byte-identical to the pre-wave app):

| Purpose | Key | Default |
|---|---|---|
| Eyes lens | `lens.eyes.enabled` | false |
| Interaction lens | `lens.interaction.enabled` | false |
| Voice lens | `lens.voice.enabled` | false |
| Hands lens | `lens.hands.enabled` | false |
| Head lens | `lens.head.enabled` | false |
| Fusion construct | `fusion.<id>.enabled` (e.g. `fusion.f1-composure.enabled`) | false |
| AU4 pitch slope / deadband | `au4.pitchCorrection.slope` / `au4.pitchCorrection.deadband` | `PitchCorrection.default…` |
| FER+ temperature (seam) | `ferplus.temperature` | 1.0 (absent ⇒ identity) |
| Dynamic FER+ weighting (seam) | `fusion.dynamicWeighting.enabled` | false |
| Fused aura | `aura.fusedMode.enabled` | false |

---

## PREP

- [ ] **P1 — Build + install to the device.** `xcodegen generate` (from `project.yml`) → Xcode → scheme `AffectLens` → Run to Apple Vision Pro (or `build_device`). A green **`build_sim`** is the compile bar; the device build is what you exercise here.
- [ ] **P2 — Launch = the first gate (self-test trap).** `AffectLensApp.init()` (`App/AffectLensApp.swift`) runs `EmotionSelfTests.runAll()` under `#if os(visionOS) && DEBUG`. It asserts all the pure math (classifier, hysteresis, fusion, congruence, replay, conformal, prosody, kinematics, thermal…) and **traps at launch on any regression**. **GATE:** the app reaches the window and the console prints **`✅ EmotionSelfTests: all checks passed`** → proceed. **On FAIL** (crash at launch): a math regression shipped — stop, fix the offending self-test, rebuild. Nothing downstream is trustworthy until this is green.
- [ ] **P3 — Calibrate neutral.** Emotion tab → tap **Face** card → **`Start`** (camera) → **`Calibrate Neutral`** → hold a relaxed face until **`Calibrated`** shows. Re-runnable anytime; persists across launches. Every AU is measured relative to *your own* Persona neutral.
- [ ] **P4 — Enable the lenses you'll test.** Flip them on the lens **cards** or in the **K-HUDs** (keys above). Leave everything else off. Fusion constructs are enabled per-row in **`Fusion constructs`**.

---

## K1 — HandTracking ↔ Persona-camera coexistence

*The load-bearing unknown for all face+hands fusion. Device-only.*

- [ ] Enable **hands** (`lens.hands.enabled`) — Hands card, or the **`Hands (K1)`** HUD toggle **`Enable hands lens`**.
- [ ] Open the **aura** (bottom ornament). This starts `ImmersiveSensingCoordinator` (`HandTrackingProvider` + `WorldTrackingProvider`) alongside the running camera.
- [ ] Open the **`Hands (K1)`** HUD and read the coexistence row: **`Face`** Hz (the face pipeline's `processedFPS`) **beside** **`Hands`** Hz (the measured provider update rate) and **`Signal`** (availability). The status dot is **green** while the coordinator reads **`running`**.
- [ ] Move your hands in view; confirm **`Energy` (m/s)**, **`Self-touch/min`**, **`Gestures/min`**, **`Head anchor` = yes** update live.

**GATE:** Face Hz **stays ~15** while Hands Hz is live and the status reads **running** → **hands+face fusion stands** (proceed to F2/F5/F8/F9/F10 hand corroboration). **On FAIL** (face FPS craters, or hands never runs on-device): keep hands **immersive-isolated** or cut it — toggle **`Enable hands lens`** OFF, record the face-FPS number seen, and note "hands isolated" in the results table. *(Reminder: hands never run in the simulator — provider unsupported — so a simulator reading is not a K1 result.)*

---

## K2 — Blink recoverability at ~15 Hz

- [ ] Enable **eyes** (`lens.eyes.enabled`) — Eyes card, or the **`Eyes / blink (K2)`** HUD toggle **`Enable eyes lens`**.
- [ ] **Calm 60 s baseline:** sit relaxed; watch **`Blinks/min`** settle and **`Resting`** learn (a trailing **`*`** means it's still on the ~15–20/min literature default). Confirm blink **`Ticks`** accumulate one mark per counted blink.
- [ ] **Forced arousal:** breath-hold or fast mental arithmetic for ~30–60 s.

**GATE:** blinks/min **rises legibly** over the calm baseline and individual blinks register as ticks → **eyes lens + F1/F3 proceed**. **On FAIL** (blinks under-sample / rate doesn't move): raise the eye-path throttle or cut the eye channel; note it (F1 and F3 depend on this).

---

## K3 / K4 — Windowed Persona-pitch fidelity + subtle-AU bandwidth

*One panel serves both: `AU4 pitch-correction · head (K3)`.*

### K3 — pitch fidelity & the anti-anger fix
- [ ] Open the **`AU4 pitch-correction · head (K3)`** HUD. With a face locked it shows **`Pitch`** (deg), **`AU4 raw`**, **`AU4 corrected`**.
- [ ] **Look down at your lap.** Watch: live **`Pitch`** tracks the tilt, and **`AU4 corrected`** drops **below** **`AU4 raw`** (the head-down brow-lower is being discounted).
- [ ] **Killer demo:** while looking down, the hero readout must **NOT** flip to **Angry**. That non-flip is the whole point of US-A0.

**THE TUNING PROCEDURE**
- **Live slope:** the **`Slope`** slider (range 0–3) in this HUD writes `au4.pitchCorrection.slope` and retunes every frame. More slope = more brow-lower subtracted per unit down-pitch.
- **Slope + deadband + seams:** Lab tab → **`Engine knobs`** exposes `au4.pitchCorrection.slope`, `au4.pitchCorrection.deadband`, `ferplus.temperature`, and the dynamic-weighting toggle together. Defaults are the shipped values; nothing here persists beyond the toggle you set.
- **SIGN-FLIP (if pitch reads inverted):** the convention is `downSign = -1` (head-down ⇒ negative pitch). If **looking down makes it *worse*** — AU4 corrected rises above raw, or the hero flips *toward* anger as you look down — the sign is inverted for your Persona. Flip **`PitchCorrection.downSign`** (its default, `defaultDownSign`, lives in `Sources/AffectEngine/ActionUnits.swift`) to `+1`. **Note:** `downSign` is a **code constant**, *not* a runtime key — only `slope` and `deadband` are UserDefaults-tunable. This sign convention is flagged unvalidated on-device (K3), so this is the expected first thing to check.

**GATE:** pitch tracks reliably and the look-down anger flip is dead → **F4 windowed MVV + all windowed head reads proceed**. **On directional-only:** gate head-down dominance/withdrawal (the "shame" gloss) to immersive; keep the windowed fix but widen head confidence.

### K4 — Persona subtle-AU bandwidth
- [ ] Turn on **`Science`** (dashboard control bar) to watch the live FACS AU meters.
- [ ] Make a **small frown** and a **slight squint**; judge the AU deltas (and **`AU4 raw`** in the K3 HUD) against how hard you feel you're expressing at the capture framing.

**GATE:** subtle AUs move adequately for your felt expression → all face-derived constructs valid. **On FAIL (poor bandwidth):** expect **widened uncertainty everywhere** — lower the global confidence ceiling and **trust the subtle-AU-dependent confidences less** (F2 load, F4 brow-morphology lean, F1's calm-face judgment). Note which readouts you'll down-weight.

---

## K5 — FoundationModels narrator latency/thermal — DEFERRED

**Not built this wave.** Narration ships as the **template narrator** only (`TemplateNarrator`, drawing strictly from `HonestyPhrases`); there is no FoundationModels narrator and no Kalman filter. Nothing to run today.

*Placeholder for the future FM item:* time `respond(to:generating:)` for a ~2–3k-token `AffectEvent` digest on-device and watch `thermalState` over a session. **GATE:** ≤~2–4 s and thermally sustainable → FM narrator ships; else template-only stays.

---

## K6 — Mic ↔ camera coexistence + prosody legibility

*Device-only. Voice owns arousal ONLY; the mic never auto-arms.*

- [ ] Enable **voice** (`lens.voice.enabled`) — Voice card, or the **`Voice / prosody (K6)`** HUD toggle **`Enable voice lens`**. Accept the mic prompt (`NSMicrophoneUsageDescription`). *(No speech-recognition permission exists — the VAD is energy/periodicity only, so words are never recognized.)*
- [ ] Read the **engine-status line** (the coexistence evidence): green dot + **`engine running · mic + camera coexisting`**. Denied/failed states read **`mic denied — enable in Settings`** / **`stopped — <reason>`**.
- [ ] **Speak calm, then excited.** Watch **`F0`**, **`Level`**, **`F0 median`**, **`Arousal`**, **`Voiced`** separate the two.
- [ ] **Laugh for real** → the **`Laughs`** counter ticks (SoundAnalysis laughter → F6 corroboration).

**GATE:** the mic tap coexists with the live camera (status running, face FPS intact) **and** F0/intensity/arousal separate calm-vs-excited **and** laughter fires → **voice channel + Face×Voice (F6) ship**. **On FAIL:** cut voice; note it. Voice is foreground-only — the mic is released when the lens is off or the app backgrounds.

---

## Construct killer demos

Each construct is a row in **`Fusion constructs`** (home). Enable its **toggle** (all `fusion.<id>.enabled`, off by default). A row that's enabled but missing a required channel shows an honest **`Needs …`** line rather than a fake reading. Confidence is always a **word** ("low/moderate/high") shown *separate* from intensity. Titles below are the **exact** UI strings.

- [ ] **F7 · `Frustration (task friction)`** — *requires Face + Interaction.* Enable the **Interaction** lens too. **Action:** a **correction-storm** — repeatedly pinch/cancel/toggle the app's own controls (lens cards, toggles, the Lab scrubber) while your Persona leans negative. **Expect:** *"Your Persona leans negative while your cancel rate climbs — consistent with frustration with the task. Task difficulty and feeling look alike here."* with the ladder **`Persona expression leans negative`** → **`Interaction friction climbing — frustration (task friction)`**. **Honesty check:** the **task-friction confound** line, and the designed starvation state under passive viewing (**`Needs interaction — use the app's controls for a while.`**).

- [ ] **F1 · `Composure under load`** ⭐ — *requires Face + Eyes.* **Action:** hold a **poker face** while driving your blink rate up (mental arithmetic / breath-hold). **Expect:** *"Your Persona face reads calm, but blink rate is elevated — composed but activated; possible regulation."* and the **congruence ring** (hero strip) **widens/desaturates** as the channels diverge. Ladder narrows `Persona face reads near-neutral` → `Blink rate elevated vs your baseline` → `Divergence sustained — composed but activated; possible regulation`. **Honesty check:** the permanent **ruled-out** rung (greyed + struck) **`Hidden-feeling or lie detection`**; a narrow-baseline Persona keeps the reading **tentative** (low-expresser gate).

- [ ] **F3 · `Fatigue ⇄ Engagement`** — *requires Eyes; accrues over session time.* **Action:** a **long session** with blinks + prolonged closures rising. **Expect:** the **one coupled bar** latches the fatigued pole **`alertness declining`**; verdict **`Alertness declining — consider a break`**. **Honesty check:** it is **ONE coupled meter, never two**; "an attention / alertness axis, not an emotion"; no medical/drowsiness claim.

- [ ] **F4 · `Frown + head-down (disambiguation)`** ⭐ — *requires Face + Head.* Enable the **Head** lens. **Action:** **look down** / lower your brow. **Expect:** the correcting rung lights — **`Brow looks lowered, but your head is down — correcting for that`** — a hedged **lean** chip (e.g. **`leans focused effort`** / `leans dejection-withdrawal`), and **no anger flip**. **Honesty check:** the disambiguation ladder plus the ruled-out rung **`A single "anger" label from a lowered brow`**, and the gaze-blind hedge ("we can't see your gaze — may stay unresolved").

- [ ] **F6 · `Corroborated positivity`** — *requires Face + Voice.* **Action:** **laugh while smiling** (a real laugh within the last ~30 s). **Expect:** namedState **`positivity echoed across channels`**. **Honesty check:** it says **"echoed / not echoed across channels," never "genuine"/"fake"** (both are on the banlist by design — this construct *replaces* the refused genuine-smile feature). No echo = un-corroborated (a null), not a verdict.

- [ ] **F10 · `Approach ⇄ Withdrawal`** — *requires Head* (richer immersive, for 6DoF). **Action:** head forward + active (approach) vs head-down + turned away (withdrawal). **Expect:** the coupled bar poles **`movement leans approach`** / **`movement leans withdrawal`**; when the face is negative the narration adds the hedged displeasure-approach vs dejection-withdrawal tie-break. **Honesty check:** a **coarse direction lean**, low-confidence, "head orientation is not gaze."

- [ ] **F8 · `Dominance display`** — *requires Head.* **Action:** head-back and level (expansion) vs head-down and away (contracted). **Expect:** poles **`expansion display`** / **`contracted / withdrawn display`**. **Honesty check:** a posture **display on the dominance axis, not a felt emotion**; no head-tilt/nod dictionary.

- [ ] **F9 · `Expansive display (head-only)`** — *requires Face + Head.* **Action:** a **strong, sustained head-back** with a non-negative face. **Expect:** namedState **`expansive high-dominance display (head-only)`**. **Honesty check:** labelled **head-only** (torso unsensable); "pride" only as a hedged gloss; the ruled-out rung **`A power-pose claim about confidence or hormones`** (Carney 2016 refusal).

- [ ] **F5 · `Corroborated arousal (multiple channels)`** — *requires Eyes + at least one of Hands / Head / Voice.* **Action:** get **two proxies elevated together** (e.g. blink rate up **and** hand energy up). **Expect:** verdict **`Corroborated arousal — multiple channels elevated together`**; with only one proxy it says **`Needs a second arousal channel — enable hands, head, or voice alongside the eyes lens.`**. **Honesty check:** arousal is a **level, not a feeling**; needs ≥2 corroborating channels (the arousal-only sibling of F1, minus the calm-face requirement).

> **Note on required channels (code wins):** F8 and F10 require **only the Head lens**; F9 requires **Face + Head**; F5 requires **Eyes** + any second arousal channel. Hands *corroborate* these when live but are **not required** — enable the head lens (open the aura for the higher-fidelity 6DoF source) and they will evaluate.

---

## Platform checks

- [ ] **SpatialEventGesture non-interference (item 11).** Enable the **Interaction** lens (`lens.interaction.enabled`); the Emotion tab attaches a `.interactionSensing` **simultaneous** gesture. **Verify every button, toggle, and lens card still responds normally** — the sensing must not swallow or perturb taps. **GATE:** normal responsiveness → interaction sensing stands. **On FAIL:** the simultaneous-gesture attachment is stealing input — note it and disable interaction sensing until fixed.

- [ ] **ESM 1-tap Health write (PRD §10 verify-item).** Tap **`How do you feel?`** → set the valence slider → **`Save report`**. Then read the **`Ground truth — for you, on this device`** section's **Health status line**:
  - **`Last report: saved to Apple Health.`** → **HKStateOfMind WRITE works on visionOS 26** (answers the open verify-item **YES**).
  - **`Last report: Health isn't available … / … wasn't allowed … / Couldn't reach Health …`** → the loop is **local-only** on this device/config; record which reason.
  Ground truth is written to the local JSONL **regardless** (never lost); the Health write is best-effort. **Record the exact status line in the results table — this is the empirical §10 answer.**

- [ ] **Trace record → Lab replay → A/B.** Emotion tab → **`Record trace`** (a distinct pulsing-red indicator; records to **`Documents/GoldenTraces`**, **features & events only, never pixels**) → interact a while → **`Stop`**. Switch to the **Lab** tab → **`Replay — deterministic re-run of a recorded trace`** → pick the trace → scrub the timeline → check the **`A/B — config A (shipped defaults) vs config B (edited)`** panel (e.g. **`B uses dynamic FER+ weighting (A = fixed 0.35)`**). **GATE:** replay is deterministic (same trace reads the same) and the A/B diff renders — or honestly reports **`Categorical A/B unavailable`** for a params-only trace.

- [ ] **Fused-aura toggle.** Home → **`Aura follows fused signals`** on/off, then open the aura. **On:** hue = valence, pulse = combined arousal, dimness = uncertainty. **Off:** the original face-intensity-driven aura (byte-identical). Confirm the toggle actually swaps behavior and off is unchanged.

- [ ] **Thermal governor (opportunistic).** If the device warms during the session, the insight feed shows the non-alarming notice **`Your device is warming up/warm/running hot — sensing eased back to keep things cool…`** and cadence drops (FER+ off at *serious*; aux channels paused at *critical*). On cooldown: **`Your device cooled down — full sensing restored.`** Verify the notice + the reduced cadence if it happens.

---

## Results table

Fill one row per keystone/check. Map PASS/FAIL to the PRD gate ("what proceeds / what gets cut or toggled").

| # | Check | PASS / FAIL | Face FPS / key reading | Notes → action taken |
|---|---|---|---|---|
| P2 | Launch self-test (no trap) | | — | trap ⇒ fix math, do not proceed |
| K1 | Hands ↔ camera coexistence | | Face __ Hz / Hands __ Hz | FAIL ⇒ hands immersive-isolated / cut |
| K2 | Blink @ ~15 Hz | | rest __ /min → forced __ /min | FAIL ⇒ raise eye throttle / cut eyes |
| K3 | Windowed pitch fidelity | | look-down anger flip: none? | directional-only ⇒ gate head-down to immersive |
| K3 | Sign convention (downSign) | | correct / inverted | inverted ⇒ flip `PitchCorrection.downSign` |
| K4 | Persona subtle-AU bandwidth | | adequate? | poor ⇒ widen uncertainty, lower ceiling |
| K5 | FM narrator | DEFERRED | — | template narrator only this wave |
| K6 | Mic ↔ camera + prosody | | calm vs excited separate? laugh fires? | FAIL ⇒ cut voice |
| F7 | Frustration (task friction) | | surfaced on correction-storm? | zero-permission windowed flagship |
| F1 | Composure under load | | ring widens? "composed but activated"? | needs K2 |
| F3 | Fatigue ⇄ Engagement | | fatigued pole latches? | one coupled meter |
| F4 | Frown + head-down ladder | | correcting rung + no anger flip? | needs K3 |
| F6 | Corroborated positivity | | "echoed across channels" on a laugh? | needs K6 |
| F10 | Approach ⇄ Withdrawal | | poles read on head move? | head lens (immersive 6DoF) |
| F8 | Dominance display | | expansion/contracted display? | head lens |
| F9 | Expansive display (head-only) | | fires on strong head-back? | head-only, power-pose refused |
| F5 | Corroborated arousal | | ≥2 proxies → verdict? | needs a 2nd arousal channel |
| — | SpatialEventGesture non-interference | | controls still respond? | item-11 on-device check |
| — | ESM Health write (§10) | | **exact status line:** | the empirical WRITE-availability answer |
| — | Trace record → Lab replay → A/B | | deterministic? diff renders? | golden-trace = CI fixture |
| — | Fused-aura toggle | | on≠off, off unchanged? | §6.4 |
| — | Thermal governor | | notice + reduced cadence? | opportunistic |

---

*Maps to PRD v2 §8.0 (keystones), §9.1 (M1 legibility, M2 zero-regression, M3 pitch bug dead, M4 greater-than-sum, M5 legible fusion, M6 per-user CCC, M7 narrator honesty), and §10 (the HKStateOfMind-WRITE verify-item).*
