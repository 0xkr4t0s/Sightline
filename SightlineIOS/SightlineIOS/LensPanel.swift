import SwiftUI

/// The lens controls (FR-CTL-001..003) in the control rail's place: primes, the focal slider, the
/// focus wheel, A/B marks with a timed rack, aperture and DoF. Every control shows what the
/// camera has (`LensPanelModel.shown`) and asks for absolute values through `perform`; the HUD's
/// `hud.lens` shows what Blender applied.
struct LensPanel: View {
    let shown: LensValues
    /// The phone's request, for the A/B marks.
    let lens: LensControls
    let rackDurationMS: Int
    let perform: (LensAction) -> Void
    let close: () -> Void

    private let primeColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Lens").font(.headline)
                    Spacer(minLength: 0)
                    Button("Done") {
                        close()
                    }
                    .font(.footnote.bold())
                    .accessibilityIdentifier("lens.done")
                }
                LazyVGrid(columns: primeColumns, spacing: 4) {
                    ForEach(LensInput.primesMM, id: \.self) { prime in
                        primeButton(prime, selected: shown.lensMM.map { LensInput.matches($0, prime) } ?? false)
                    }
                }
                caption("Focal", shown.lensMM.map { String(format: "%.0f mm", Double($0)) } ?? "—")
                Slider(
                    value: Binding(
                        get: { LensInput.focalPosition(shown.lensMM ?? 50) },
                        set: { perform(.lens(LensInput.focal(atPosition: $0))) })
                )
                .accessibilityLabel("Focal length")
                .accessibilityValue(shown.lensMM.map { String(format: "%.0f mm", Double($0)) } ?? "—")
                .accessibilityIdentifier("lens.focal")
                caption("Focus", Self.metres(shown.focusM))
                FocusWheel(metres: shown.focusM) { perform(.focus($0)) }
                marks
                rackRow
                LensStepper(
                    title: "Rack time",
                    value: String(format: "%.1f s", Double(rackDurationMS) / 1000),
                    identifier: "lens.rackDuration", downLabel: "Shorter rack", upLabel: "Longer rack"
                ) { perform(.rackDuration(longer: $0)) }
                LensStepper(
                    title: "Aperture", value: shown.fstop.map { String(format: "f/%.3g", Double($0)) } ?? "f/—",
                    identifier: "lens.aperture", downLabel: "Wider aperture", upLabel: "Narrower aperture"
                ) { narrower in
                    perform(.fstop(LensInput.aperture(from: shown.fstop ?? 2.8, wider: !narrower)))
                }
                HStack {
                    Text("DoF").font(.caption)
                    Spacer(minLength: 4)
                    Toggle(
                        "Depth of field",
                        isOn: Binding(
                            get: { shown.dofOn ?? false },
                            set: { perform(.dof($0)) })
                    )
                    .labelsHidden()
                    .accessibilityIdentifier("lens.dof")
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.white)
        .tint(.yellow)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lens.panel")
    }

    private func primeButton(_ prime: Float, selected: Bool) -> some View {
        Button {
            perform(.lens(prime))
        } label: {
            Text(String(format: "%.0f", Double(prime)))
                .font(.footnote.monospacedDigit().bold())
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    selected ? Color.yellow.opacity(0.35) : Color.white.opacity(0.12), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "%.0f millimetre prime", Double(prime)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(String(format: "lens.prime.%.0f", Double(prime)))
    }

    private var marks: some View {
        HStack(spacing: 4) {
            markButton("A", target: VCPRackFocus.targetA, value: lens.markA)
            markButton("B", target: VCPRackFocus.targetB, value: lens.markB)
        }
    }

    private func markButton(_ name: String, target: UInt8, value: Float?) -> some View {
        Button {
            perform(.mark(target))
        } label: {
            VStack(spacing: 0) {
                Text("Set \(name)").font(.caption.bold())
                Text(Self.metres(value)).font(.caption2.monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set mark \(name)")
        .accessibilityValue(Self.metres(value))
        .accessibilityIdentifier("lens.set\(name)")
    }

    private var rackRow: some View {
        let target = LensInput.rackTarget(focus: shown.focusM, markA: lens.markA, markB: lens.markB)
        let title = target.map { "Rack to \($0 == VCPRackFocus.targetA ? "A" : "B")" } ?? "Rack A↔B"
        return Button {
            perform(.rack)
        } label: {
            Text(title)
                .font(.footnote.bold())
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Color.yellow.opacity(target == nil ? 0.1 : 0.35), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .accessibilityLabel(title)
        .accessibilityIdentifier("lens.rack")
    }

    private func caption(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    static func metres(_ value: Float?) -> String {
        value.map { String(format: "%.2f m", Double($0)) } ?? "—"
    }
}

/// A title and value over − and + buttons; `step(true)` is the + button.
private struct LensStepper: View {
    let title: String
    let value: String
    let identifier: String
    let downLabel: String
    let upLabel: String
    let step: (Bool) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Text(value)
                    .monospacedDigit()
                    .accessibilityLabel(title)
                    .accessibilityValue(value)
                    .accessibilityIdentifier(identifier)
            }
            .font(.caption)
            HStack(spacing: 4) {
                stepButton("minus", downLabel, id: "\(identifier).down") { step(false) }
                stepButton("plus", upLabel, id: "\(identifier).up") { step(true) }
            }
        }
    }

    private func stepButton(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.bold())
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A follow-focus wheel: a logarithmic distance ruler under a fixed index. Dragging moves the ruler
/// with the finger (left brings farther distances under the index); VoiceOver swipes step it.
private struct FocusWheel: View {
    let metres: Float?
    let change: (Float) -> Void
    @State private var dragStart: Float?

    var body: some View {
        let current = Double(metres ?? 2)
        Canvas { context, size in
            let perDoubling = LensInput.wheelPointsPerDoubling
            let centre = log2(current)
            let mid = size.width / 2
            // Quarter-doubling ticks over the visible span; whole doublings are longer and labelled.
            let span = Double(size.width) / 2 / perDoubling + 1
            var quarter = ((centre - span) * 4).rounded(.down)
            while quarter <= (centre + span) * 4 {
                let x = mid + CGFloat((quarter / 4 - centre) * perDoubling)
                let whole = quarter.truncatingRemainder(dividingBy: 4) == 0
                let tick = Path { path in
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x, y: size.height * (whole ? 0.45 : 0.7)))
                }
                context.stroke(tick, with: .color(.white.opacity(0.7)), lineWidth: 1)
                if whole {
                    let value = pow(2, quarter / 4)
                    let label = value < 1 ? String(format: "%.2g", value) : String(format: "%.0f", value)
                    context.draw(
                        Text(label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.8)),
                        at: CGPoint(x: x, y: size.height * 0.22))
                }
                quarter += 1
            }
            let index = Path { path in
                path.move(to: CGPoint(x: mid, y: 0))
                path.addLine(to: CGPoint(x: mid, y: size.height))
            }
            context.stroke(index, with: .color(.yellow), lineWidth: 2)
        }
        .frame(height: 32)
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? Float(current)
                    dragStart = start
                    change(LensInput.wheel(from: start, dragX: drag.translation.width))
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Focus wheel")
        .accessibilityValue(LensPanel.metres(metres))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(LensInput.wheelStep(from: Float(current), farther: true))
            case .decrement: change(LensInput.wheelStep(from: Float(current), farther: false))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("lens.focus")
    }
}
