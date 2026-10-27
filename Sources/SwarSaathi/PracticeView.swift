import SwiftUI
import UIKit

struct PracticeView: View {
    @StateObject private var vm: PracticeViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(sa: Double, engine: PitchEngine, lowerHz: Double? = nil, upperHz: Double? = nil) {
        _vm = StateObject(wrappedValue: PracticeViewModel(sa: sa, engine: engine, lowerHz: lowerHz, upperHz: upperHz))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let msg = vm.errorMessage {
                    ErrorBanner(message: msg, showSettings: vm.permissionDenied)
                }
                if let b = vm.banner {
                    ErrorBanner(message: b)
                }

                configurationCard
                liveCard
                graphCard
                controls
                sequenceCard

                if vm.phase == .finished {
                    SummaryView(summary: vm.summary, results: vm.results,
                                targets: vm.targets) { vm.prepareAgain() }
                    if let url = vm.auditURL {
                        ShareLink(item: url) { Label("Share audit JSON", systemImage: "square.and.arrow.up") }
                            .font(.subheadline.bold())
                    }
                }
            }
            .padding(20)
            .animation(.easeInOut, value: vm.phase == .finished)
        }
        .background(Color.swarBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            vm.shutdown()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                UIApplication.shared.isIdleTimerDisabled = false
                vm.shutdown()
            } else if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    // MARK: Sections

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guided exercise").font(.headline)
            Picker("Alankaar", selection: $vm.selectedExerciseIndex) {
                ForEach(Array(vm.exercises.enumerated()), id: \.offset) { index, exercise in
                    Text(exercise.name).tag(index)
                }
            }
            .disabled(vm.phase == .running || vm.referencePlaying || vm.isStarting)
            Stepper("Tempo: \(Int(vm.bpm)) BPM", value: $vm.bpm, in: 40...120, step: 4)
                .disabled(vm.phase == .running || vm.referencePlaying || vm.isStarting)
            Text("Illustrative Shuddha ratios. Listen to the full reference, then sing once after the three-beat count-in. Targets follow the clock even when a note is wrong or missing.")
                .font(.footnote).foregroundColor(.secondary)
            if vm.exercises.isEmpty {
                Text("No exercise fits the measured comfortable range. Return to calibration.")
                    .font(.footnote).foregroundColor(.swarOrange)
            }
        }.card()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alankaar Practice").font(.largeTitle.bold())
            Text("Sing along with the notes and find out how accurately you match them.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Label("Your Sa: \(Int(vm.sa)) Hz · \(PitchMath.noteText(vm.sa))", systemImage: "tuningfork")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.swarPurple.opacity(0.12))
                .foregroundColor(.swarPurple)
                .clipShape(Capsule())
        }
    }

    private var liveCard: some View {
        let target = vm.currentTarget
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(vm.phase == .finished ? "Done" : target.label)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                    startPoint: .leading, endPoint: .trailing))
                Spacer()
                Text("Note \(min(vm.currentIndex + 1, vm.targets.count)) of \(vm.targets.count)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Text("Expected: \(target.label) – \(hzText(target.frequency))")
                .font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected").font(.caption).foregroundColor(.secondary)
                    Text(hzText(vm.detectedHz))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Difference").font(.caption).foregroundColor(.secondary)
                    Text(vm.cents.map { String(format: "%+.0f cents", $0) } ?? "— cents")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            CentsMeter(cents: vm.cents)
            Text(vm.feedback)
                .font(.headline)
                .foregroundColor(vm.feedbackKind.color)
                .animation(.easeInOut(duration: 0.15), value: vm.feedback)
            ProgressView(value: vm.holdProgress)
                .tint(.swarGreen)
            Text("Guided note progress · not a successful-hold requirement")
                .font(.caption2).foregroundColor(.secondary)
            if vm.phase == .running {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").foregroundColor(.swarPurple)
                    LevelBar(level: vm.level)
                }
            }
        }
        .card()
    }

    private var graphCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your pitch over time").font(.headline)
            PitchGraphView(points: vm.graphPoints,
                           ladder: vm.ladder,
                           currentTarget: vm.currentTarget.frequency,
                           thresholds: vm.thresholds,
                           active: vm.phase == .running,
                           timeline: vm.timeline,
                           sessionStart: vm.sessionStart)
                .frame(height: 300)
            HStack(spacing: 16) {
                legend(.swarPurple, "Target note")
                legend(.swarBlue, "Your voice")
            }
            Text("Blue above the purple line means you're singing higher than the note; below means lower. The shaded band is the \"on target\" zone.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .card()
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 18, height: 4)
            Text(text).font(.caption).foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        Group {
            if vm.phase == .running {
                Button { vm.finishEarly() } label: { Label("Stop and report incomplete attempt", systemImage: "stop.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            } else if vm.phase == .idle {
                Button { vm.referencePlaying ? vm.stopReference() : vm.playReference() } label: {
                    Label(vm.referencePlaying ? "Stop reference" : "Play reference Alankaar", systemImage: vm.referencePlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                .disabled(vm.isStarting || vm.exercises.isEmpty)
                Button { vm.start() } label: { Label("Start Practice", systemImage: "mic.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!vm.canStart)
            }
        }
    }

    private var sequenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alankaar").font(.headline)
            Text("One beat per note. Missing notes remain in the full-exercise score.")
                .font(.footnote)
                .foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(vm.targets) { t in
                    NoteCardView(target: t,
                                 result: vm.results[t.index],
                                 isCurrent: vm.phase == .running && vm.currentIndex == t.index,
                                 thresholds: vm.thresholds)
                }
            }
        }
        .card()
    }
}

struct NoteCardView: View {
    let target: NoteTarget
    let result: NoteResult?
    let isCurrent: Bool
    let thresholds: AccuracyThresholds

    private var accuracy: Accuracy? {
        guard let result = result else { return nil }
        if result.accuracyPercent < 80 { return .needsAdjustment }
        return result.signedCents.map { thresholds.classify($0) }
    }

    private var icon: String {
        if isCurrent { return "waveform" }
        guard let r = result else { return "circle" }
        if r.detectedHz == nil { return "minus.circle" }
        return r.accuracyPercent < 80 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(target.label).font(.headline)
            Text("\(Int(target.frequency.rounded())) Hz")
                .font(.caption2)
                .foregroundColor(.secondary)
            if let result = result {
                Text(String(format: "%.0f%% match", result.accuracyPercent))
                    .font(.caption2)
            }
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(isCurrent ? .swarPurple : (accuracy?.color ?? .gray.opacity(0.4)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background((accuracy?.color ?? Color.gray).opacity(accuracy == nil ? 0.08 : 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isCurrent ? Color.swarPurple : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}
