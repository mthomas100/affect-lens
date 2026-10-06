//
//  LabModeView.swift
//  AffectLens
//
//  LAB MODE — the developer's on-device workbench (US-lab, PRD v2 §6.8). A tab whose
//  selection keeps the emotion capture running exactly like the Emotion tab (both share
//  `ContentView`'s one camera feed), so the whole live pipeline stays
//  hot while Lab observes it. Five stacked sections, functional over pretty:
//
//   1. CHANNEL COLUMNS — the six lenses side by side (interpretation meter + top
//      features + honest availability), each detachable into its own window, for
//      spotting congruence/conflict live.
//   2. EVENT LOG + r_k AUDIT — the raw `AffectEvent` bus (newest first, BOCPD shifts
//      highlighted) beside the per-channel reliability table — the fusion audit.
//   3. REPLAY — pick a recorded golden trace, scrub it through the SAME downstream
//      pipeline the CI fixture uses (`TraceReplayer.replaySeries`, deterministic), and
//      run an A/B of two configs (params always; the categorical fusion weight when the
//      trace carries geometry+FER+ distributions) with a plain numeric diff.
//   4. GROUND TRUTH — the ESM overlay: n, per-user CCC, recent felt-vs-inferred pairs,
//      Health save status (reuses `GroundTruthSection`).
//   5. ENGINE KNOBS — the AU4 pitch tuners (US-A0, same keys as the dashboard) + the
//      FER+ temperature + dynamic-weighting toggle (US-C8 keys, first UI surface).
//
//  Honesty (PRD §6.7): prose runs through `HonestyPhrases`; the r_k table and the A/B
//  diffs are numeric/technical, which the spec sanctions.
//

#if os(visionOS)

import SwiftUI

// MARK: - LabModeView

struct LabModeView: View {
    let hub: AffectHub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LabChannelColumns(hub: hub)
                LabEventLogSection(hub: hub)
                LabReplaySection(hub: hub)
                LabGroundTruthSection(hub: hub)
                LabEngineKnobs()
            }
            .padding(8)
        }
        // PRD §4.2 F7 names "the Lab-Mode replay scrubber" as an interaction surface —
        // Lab manipulation (scrubbing, knob drags, A/B toggles) feeds the interaction
        // lens exactly like the Emotion tab's controls. Simultaneous gesture; gated
        // internally on the lens being enabled — zero collection when off.
        .interactionSensing(channel: hub.interaction)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Lab", systemImage: "flask")
                .font(.title2.bold())
            Text(HonestyPhrases.labBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1. Channel columns

/// The six lenses side by side (US-lab §6.8 (1)). Live lenses bright; the rest greyed
/// with the honest reason from `Lens.availability`. Each column detaches into the
/// `lens-detail` window.
private struct LabChannelColumns: View {
    let hub: AffectHub

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Channels — side by side")
                .font(.headline)
            Text(HonestyPhrases.labColumnsNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Lens.allCases) { lens in
                        LabChannelColumn(lens: lens, hub: hub)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// One compact channel column: interpretation meter(s) + a few top features + a detach
/// button; greyed with an honest reason when the lens isn't live.
private struct LabChannelColumn: View {
    let lens: Lens
    let hub: AffectHub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let avail = lens.availability(in: hub)
        let reading = LabChannelColumn.reading(for: lens, hub: hub)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: lens.systemImage)
                Text(lens.title).font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(avail.isAvailable ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
            }

            if avail.isAvailable {
                if lens == .face {
                    LensMeterGauge(label: "Valence", meter: reading.valence)
                }
                LensMeterGauge(label: "Arousal", meter: reading.arousal)
                let feats = LabChannelColumn.topFeatures(reading)
                if feats.isEmpty {
                    Text("No Δ features yet.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ForEach(feats, id: \.0) { name, value in
                        HStack(spacing: 4) {
                            Text(name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(value).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(LabChannelColumn.reason(avail))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            Button {
                openWindow(id: "lens-detail", value: lens)
            } label: {
                Label("Detach", systemImage: "rectangle.on.rectangle").font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 194, height: 244, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10)))
        .opacity(avail.isAvailable ? 1 : 0.55)
    }

    /// The channel-generic reading for a lens (each channel adopts `AffectChannel.latest`).
    static func reading(for lens: Lens, hub: AffectHub) -> ChannelReading {
        switch lens {
        case .face: return hub.face.latest
        case .eyes: return hub.eyes.latest
        case .hands: return hub.hands.latest
        case .head: return hub.head.latest
        case .voice: return hub.voice.latest
        case .interaction: return hub.interaction.latest
        }
    }

    /// Up to three delta-from-baseline features, formatted compactly.
    static func topFeatures(_ reading: ChannelReading) -> [(String, String)] {
        reading.features
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .prefix(3)
            .map { ($0.key.rawValue, String(format: "%+.2f", $0.value)) }
    }

    static func reason(_ avail: LensAvailability) -> String {
        switch avail {
        case .available: return ""
        case .unavailableButEnableable(let cta): return cta
        case .unavailable(let reason): return reason
        }
    }
}

// MARK: - 2. Event log + r_k audit

/// The raw `AffectEvent` bus (newest first) beside the per-channel reliability audit
/// table (US-lab §6.8 (2)).
private struct LabEventLogSection: View {
    let hub: AffectHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event bus & fusion audit").font(.headline)
            Text(HonestyPhrases.labEventLogNote)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                eventList
                RkAuditTable(hub: hub)
                    .frame(width: 320)
            }
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AffectEvent stream — newest first (\(hub.events.count))")
                .font(.caption.bold())
            if hub.events.isEmpty {
                Text("No events yet — a state-shift, congruence break, or construct activation lands here.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(hub.events.reversed()) { event in
                            LabEventRow(event: event, constructTitle: event.constructID.flatMap { id in
                                hub.fusionRegistry.modes.first { $0.id == id }?.title
                            })
                        }
                    }
                    .padding(2)
                }
                .frame(height: 280)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One event row: kind / channel / construct / magnitude+confidence / evidence. BOCPD
/// `.stateShift` (and cross-channel `.congruenceBreak`) rows are highlighted.
private struct LabEventRow: View {
    let event: AffectEvent
    /// The construct's display title (the raw id is only the settings key).
    var constructTitle: String?

    private var highlighted: Bool {
        event.kind == .stateShift || event.kind == .congruenceBreak
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.kind.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(highlighted ? .orange : .primary)
                if let c = event.channel {
                    Text(c.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                if let cid = event.constructID {
                    Text(constructTitle ?? cid).font(.caption2).foregroundStyle(.purple)
                }
                Spacer(minLength: 4)
                Text(String(format: "m %.2f · c %.2f", event.magnitude, event.confidence))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !event.evidence.isEmpty {
                Text(event.evidence.map(\.rawValue).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((highlighted ? Color.orange.opacity(0.12) : Color.white.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The r_k audit table (US-lab §6.8 (2)): per arousal-voting channel, the exact
/// `ChannelConfidence` inputs the hub feeds congruence and their product r_k. Recomputes
/// the hub's formula read-only (same inputs ⇒ same numbers) — the legible fusion audit.
private struct RkAuditTable: View {
    let hub: AffectHub

    private struct Row: Identifiable {
        let id: String
        let qCal: Double
        let a: Double
        let qData: Double
        let rk: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reliability audit  r_k = q_cal · a · q_data")
                .font(.caption.bold())
            Text("Δt ≈ 0 ⇒ recency ≈ 1 (omitted). Only arousal-voting channels appear.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            headerRow
            let rows = auditRows()
            if rows.isEmpty {
                Text("No channel is voting right now.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { r in
                    HStack(spacing: 4) {
                        Text(r.id).font(.caption2).frame(width: 78, alignment: .leading)
                        cell(r.qCal); cell(r.a); cell(r.qData)
                        Text(String(format: "%.2f", r.rk))
                            .font(.caption2.monospacedDigit().bold())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text("channel").font(.caption2.bold()).frame(width: 78, alignment: .leading)
            head("q_cal"); head("a"); head("q_data")
            Text("r_k").font(.caption2.bold()).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func head(_ s: String) -> some View {
        Text(s).font(.caption2.bold()).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func cell(_ v: Double) -> some View {
        Text(String(format: "%.2f", v))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Mirror the hub's `ingestCongruence` vote gating + `ChannelConfidence` inputs.
    private func auditRows() -> [Row] {
        func a(_ av: ChannelAvailability) -> Double {
            switch av { case .live: return 1; case .degraded: return 0.5; case .unavailable: return 0 }
        }
        func row(_ id: String, qCal: Double, av: ChannelAvailability, qData: Double) -> Row {
            let rk = ChannelConfidence.confidence(calibrationQuality: qCal, availability: av,
                                                  secondsSinceUpdate: 0, tau: 1, dataQuality: qData)
            return Row(id: id, qCal: qCal, a: a(av), qData: qData, rk: rk)
        }
        var rows: [Row] = []
        let face = hub.face.reading
        if face.faceDetected {
            rows.append(row("face", qCal: hub.face.isCalibrated ? 1 : 0.5, av: .live, qData: face.quality))
        }
        if hub.eyes.isEnabled, hub.eyes.signedArousalDelta != nil {
            rows.append(row("eyes", qCal: hub.eyes.restingLearned ? 1 : 0.5,
                            av: hub.eyes.availability, qData: hub.eyes.quality))
        }
        if hub.hands.isEnabled, hub.hands.signedArousalDelta != nil {
            rows.append(row("hands", qCal: hub.hands.restingLearned ? 1 : 0.5,
                            av: hub.hands.availability, qData: hub.hands.quality))
        }
        if hub.head.isEnabled, hub.head.signedArousalDelta != nil {
            rows.append(row("head", qCal: hub.head.restingLearned ? 1 : 0.5,
                            av: hub.head.availability, qData: hub.head.quality))
        }
        return rows
    }
}

// MARK: - 3. Replay scrubber + A/B

/// The replay workbench (US-lab §6.8 (3)+(4)): pick a recorded trace, scrub it through
/// `TraceReplayer.replaySeries` (deterministic), and A/B two configs with a numeric diff.
private struct LabReplaySection: View {
    let hub: AffectHub

    @State private var traces: [URL] = []
    @State private var selected: URL?
    @State private var trace: Trace?
    @State private var series: TraceReplayer.ReplayTickSeries?
    @State private var scrub: Double = 0
    @State private var loadError: String?

    // Config B knobs (config A is always `.default`).
    @State private var bCongruenceEnter: Double = TraceReplayer.ReplayConfig.default.congruenceEnter
    @State private var bF1Enter: Double = TraceReplayer.ReplayConfig.default.f1Enter
    @State private var bDynamicWeight = false
    @State private var ab: (a: TraceReplayer.ReplayTickSeries, b: TraceReplayer.ReplayTickSeries)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replay — deterministic re-run of a recorded trace").font(.headline)
            Text(HonestyPhrases.labReplayNote)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            picker
            if let error = loadError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            if let trace, let series {
                scrubber(trace: trace, series: series)
                abPanel(trace: trace)
            } else {
                Text("Pick a trace to load. Record one from the Emotion tab first if the list is empty.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { traces = hub.traceRecorder.listTraces() }
    }

    private var picker: some View {
        HStack(spacing: 10) {
            Button {
                traces = hub.traceRecorder.listTraces()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)

            Menu {
                if traces.isEmpty {
                    Text("No traces in Documents/GoldenTraces")
                } else {
                    ForEach(traces, id: \.self) { url in
                        Button(url.lastPathComponent) { load(url) }
                    }
                }
            } label: {
                Label(selected?.lastPathComponent ?? "Select trace…", systemImage: "list.bullet.rectangle")
                    .font(.caption).lineLimit(1)
            }
        }
    }

    private func load(_ url: URL) {
        selected = url
        loadError = nil
        ab = nil
        do {
            let t = try Trace(contentsOf: url)
            trace = t
            series = TraceReplayer.replaySeries(t)
            scrub = 0
        } catch {
            trace = nil; series = nil
            loadError = "Couldn't load trace: \(error.localizedDescription)"
        }
    }

    // MARK: Scrubber

    @ViewBuilder
    private func scrubber(trace: Trace, series: TraceReplayer.ReplayTickSeries) -> some View {
        let count = series.ticks.count
        let i = min(max(0, Int(scrub.rounded())), max(0, count - 1))
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)
            Text("\(count) ticks · header notes: \(trace.header.notes.isEmpty ? "—" : trace.header.notes)")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)

            if count > 1 {
                Slider(value: $scrub, in: 0...Double(count - 1), step: 1)
            }
            EventsTimelineStrip(trace: trace, scrubIndex: i)
                .frame(height: 26)

            if i < trace.ticks.count, i < series.ticks.count {
                let recorded = trace.ticks[i]
                let replayed = series.ticks[i]
                HStack(alignment: .top, spacing: 16) {
                    recordedColumn(tick: recorded, index: i)
                    replayedColumn(series: series, upTo: i, tick: replayed)
                }
                if !recorded.eventsEmitted.isEmpty {
                    Text("events @ tick: " + recorded.eventsEmitted.map { $0.kind.rawValue }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }

    private func recordedColumn(tick: TraceTick, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recorded face @ \(index)").font(.caption.bold())
            metric("dominant", tick.faceReading.faceDetected ? tick.faceReading.dominant.displayName : "no face")
            metric("valence", String(format: "%+.2f", tick.faceReading.valence))
            metric("arousal", String(format: "%+.2f", tick.faceReading.arousal))
            if let g = tick.geometryDistribution {
                metric("geom", g.dominant.emotion.displayName)
            }
            if let m = tick.mlDistribution {
                metric("FER+", m.dominant.emotion.displayName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func replayedColumn(series: TraceReplayer.ReplayTickSeries,
                                upTo i: Int, tick: TraceReplayer.ReplayTick) -> some View {
        let blinksSoFar = series.ticks[0...i].reduce(0) { $0 + ($1.blink ? 1 : 0) }
        let shiftsSoFar = series.ticks[0...i].reduce(0) { $0 + ($1.stateShift ? 1 : 0) }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Replayed downstream @ \(i)").font(.caption.bold())
            metric("blinks so far", "\(blinksSoFar)")
            metric("shifts so far", "\(shiftsSoFar)")
            metric("congruence", tick.congruence.rawValue)
            metric("F1 composure", tick.f1Active ? String(format: "active (%.2f)", tick.f1Score) : "—")
            if let d = tick.refusedDominant {
                metric("re-fused", d.displayName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: A/B panel

    @ViewBuilder
    private func abPanel(trace: Trace) -> some View {
        Divider().opacity(0.4)
        VStack(alignment: .leading, spacing: 8) {
            Text("A/B — config A (shipped defaults) vs config B (edited)").font(.caption.bold())
            HStack(spacing: 8) {
                Text("B congruence-enter").font(.caption2).foregroundStyle(.tertiary)
                Slider(value: $bCongruenceEnter, in: -1...1)
                Text(String(format: "%.2f", bCongruenceEnter)).font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("B F1 enter").font(.caption2).foregroundStyle(.tertiary)
                Slider(value: $bF1Enter, in: 0...1)
                Text(String(format: "%.2f", bF1Enter)).font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            Toggle(isOn: $bDynamicWeight) {
                Text("B uses dynamic FER+ weighting (A = fixed 0.35)").font(.caption2)
            }
            Button {
                runAB(trace: trace)
            } label: {
                Label("Run A/B", systemImage: "arrow.left.arrow.right").font(.caption)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)

            if let ab { abDiff(ab.a, ab.b) }
        }
    }

    private func runAB(trace: Trace) {
        let a = TraceReplayer.ReplayConfig.default
        var b = TraceReplayer.ReplayConfig.default
        b.congruenceEnter = bCongruenceEnter
        b.f1Enter = bF1Enter
        b.mlWeight = bDynamicWeight ? .dynamic : .fixed(0.35)
        ab = (TraceReplayer.replaySeries(trace, config: a),
              TraceReplayer.replaySeries(trace, config: b))
    }

    @ViewBuilder
    private func abDiff(_ a: TraceReplayer.ReplayTickSeries, _ b: TraceReplayer.ReplayTickSeries) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            diffRow("metric", "A", "B", bold: true)
            diffRow("blinks", "\(a.blinkCount)", "\(b.blinkCount)")
            diffRow("state shifts", "\(a.stateShiftCount)", "\(b.stateShiftCount)")
            diffRow("congruence breaks", "\(a.congruenceBreakCount)", "\(b.congruenceBreakCount)")
            diffRow("F1 activations", "\(a.f1Activations)", "\(b.f1Activations)")
            diffRow("F7 activations", "\(a.f7Activations)", "\(b.f7Activations)")

            // Categorical A/B only when the weight strategy differs AND the trace carries
            // the geometry+FER+ distributions the re-fusion needs.
            if bDynamicWeight, a.hasDistributions {
                let idx = zip(a.ticks, b.ticks).enumerated().compactMap { i, pair in
                    pair.0.refusedDominant != pair.1.refusedDominant ? i : nil
                }
                if idx.isEmpty {
                    Text("Re-fused dominant: identical across the trace.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Re-fused dominant diverges at ticks: "
                         + idx.prefix(12).map(String.init).joined(separator: ", ")
                         + (idx.count > 12 ? " …(\(idx.count))" : ""))
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if bDynamicWeight {
                Text("Categorical A/B unavailable — this trace carries no geometry+FER+ distributions (params-only).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func diffRow(_ a: String, _ b: String, _ c: String, bold: Bool = false) -> some View {
        HStack {
            Text(a).font(bold ? .caption2.bold() : .caption2).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).font(bold ? .caption2.bold() : .caption2.monospacedDigit()).frame(width: 60, alignment: .trailing)
            Text(c).font(bold ? .caption2.bold() : .caption2.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(value).font(.caption2.monospacedDigit())
        }
    }
}

/// A compact events strip over the trace: an orange tick per frame that emitted events,
/// plus the white scrub cursor.
private struct EventsTimelineStrip: View {
    let trace: Trace
    let scrubIndex: Int

    var body: some View {
        Canvas { ctx, size in
            let n = trace.ticks.count
            guard n > 0 else { return }
            func x(_ i: Int) -> CGFloat { size.width * CGFloat(i) / CGFloat(max(1, n - 1)) }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(baseline, with: .color(.gray.opacity(0.35)), lineWidth: 1)

            for (i, tick) in trace.ticks.enumerated() where !tick.eventsEmitted.isEmpty {
                var mark = Path()
                mark.move(to: CGPoint(x: x(i), y: 2))
                mark.addLine(to: CGPoint(x: x(i), y: size.height - 2))
                ctx.stroke(mark, with: .color(.orange.opacity(0.85)), lineWidth: 2)
            }

            var cursor = Path()
            cursor.move(to: CGPoint(x: x(scrubIndex), y: 0))
            cursor.addLine(to: CGPoint(x: x(scrubIndex), y: size.height))
            ctx.stroke(cursor, with: .color(.white), lineWidth: 1.5)
        }
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 4. Ground truth

/// The ESM ground-truth overlay (US-lab §6.8 (5)): reuses `GroundTruthSection` (n, CCC,
/// conformal, Health) and adds a compact recent felt-vs-inferred list.
private struct LabGroundTruthSection: View {
    let hub: AffectHub

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroundTruthSection(hub: hub)
            recentReports
        }
    }

    private var recentReports: some View {
        let recent = Array(hub.esm.reports.suffix(6).reversed())
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recent reports — felt vs inferred").font(.caption.bold())
            if recent.isEmpty {
                Text("No reports yet.").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(recent) { r in
                    HStack {
                        Text(String(format: "felt %+.2f", r.valence))
                            .font(.caption2.monospacedDigit())
                        if !r.labels.isEmpty {
                            Text(r.labels.joined(separator: ",")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(r.inferredValence.map { String(format: "inferred %+.2f", $0) } ?? "no face")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 5. Engine knobs

/// The engine-knob tuners (US-lab §6.8 (6)): the AU4 pitch slope/deadband (US-A0, same
/// AppStorage keys as the dashboard) + the FER+ temperature + dynamic-weighting toggle
/// (US-C8 keys — their first UI surface). All read the SAME `UserDefaults` keys the
/// engine reads each frame, so they tune LIVE inference; defaults are the shipped values.
private struct LabEngineKnobs: View {
    @AppStorage("au4.pitchCorrection.slope") private var slope = PitchCorrection.defaultSlope
    @AppStorage("au4.pitchCorrection.deadband") private var deadband = PitchCorrection.defaultDeadband
    @AppStorage("ferplus.temperature") private var temperature = 1.0
    @AppStorage("fusion.dynamicWeighting.enabled") private var dynamicWeighting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine knobs").font(.headline)
            Text(HonestyPhrases.labEngineKnobsNote)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            knob("AU4 pitch slope", value: $slope, range: 0...3,
                 defaultValue: PitchCorrection.defaultSlope)
            knob("AU4 pitch deadband (rad)", value: $deadband, range: 0...0.5,
                 defaultValue: PitchCorrection.defaultDeadband)
            knob("FER+ temperature (T)", value: $temperature, range: 0.5...3,
                 defaultValue: 1.0)
            Toggle(isOn: $dynamicWeighting) {
                Text("Dynamic FER+ weighting (Aviezer, US-C8)").font(.caption)
            }
            Text("AU4 correction keeps looking-down from faking anger; T flattens (>1) or sharpens (<1) FER+ before the pool; dynamic weighting leans on FER+ as the face's intensity/ambiguity rise.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                slope = PitchCorrection.defaultSlope
                deadband = PitchCorrection.defaultDeadband
                temperature = 1.0
                dynamicWeighting = false
            } label: {
                Label("Reset to shipped defaults", systemImage: "arrow.counterclockwise").font(.caption2)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func knob(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                      defaultValue: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 168, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(abs(value.wrappedValue - defaultValue) < 1e-9 ? Color.secondary : Color.orange)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - LensDetailWindow (the detachable lens window content, US-lab §6.8)

/// The content of the `lens-detail` window (US-lab). Presents the lens focus view for the
/// detached `Lens` value, reusing the existing lens views. READ-ONLY for `.face`: the
/// detached window never owns the camera (the main window keeps the single
/// `CameraFeed`), so the face card is a live summary, not the full dashboard.
struct LensDetailWindow: View {
    @Environment(AppModel.self) private var appModel
    let lens: Lens?

    var body: some View {
        let hub = appModel.affectHub
        Group {
            switch lens {
            case .eyes:
                EyesLensView(eyes: hub.eyes)
            case .interaction:
                InteractionLensView(interaction: hub.interaction)
            case .voice:
                VoiceLensView(voice: hub.voice, interaction: hub.interaction)
            case .hands:
                HandsLensView(hands: hub.hands, coordinator: hub.immersiveSensing,
                              interaction: hub.interaction)
            case .head:
                HeadLensView(head: hub.head, interaction: hub.interaction)
            case .face, .none:
                faceReadOnly(hub: hub)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // PRD §4.2 F7 names "detachable-volume drags" as an interaction surface — a
        // detached lens window feeds the interaction lens like the main window's
        // controls. Simultaneous; gated internally on the lens being enabled.
        .interactionSensing(channel: appModel.affectHub.interaction)
    }

    private func faceReadOnly(hub: AffectHub) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EmotionHeroView(reading: hub.face.reading,
                                conformalLabels: hub.conformalLabels(for: hub.face.reading.distribution))
                Text(HonestyPhrases.labDetachedFaceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#endif
