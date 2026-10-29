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

                if vm.phase == .finished {
                    SummaryView(summary: vm.summary, results: vm.results,
                                targets: vm.targets, auditURL: vm.auditURL) { vm.prepareAgain() }
                } else {
                    if vm.phase == .idle { configurationCard }
                    controls
                    if vm.phase == .running { liveCard }
                    graphCard
                    sequenceCard
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
            Text("Choose your Alankaar").font(.headline)
            Picker("Alankaar", selection: $vm.selectedExerciseIndex) {
                ForEach(Array(vm.exercises.enumerated()), id: \.offset) { index, exercise in
                    Text(exercise.name).tag(index)
                }
            }
            .disabled(vm.phase == .running || vm.referencePlaying || vm.isStarting)
            Stepper("Tempo: \(Int(vm.bpm)) BPM", value: $vm.bpm, in: 40...120, step: 4)
                .disabled(vm.phase == .running || vm.referencePlaying || vm.isStarting)
            Text("Sing one note per beat after the count-in.")
                .font(.footnote).foregroundColor(.secondary)
            if let message = vm.rangeMessage {
                Text(message)
                    .font(.footnote).foregroundColor(.swarOrange)
            }
        }.card()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alankaar Practice").font(.largeTitle.bold())
            Text(vm.phase == .finished ? "See how each note went." : "Follow the notes at a comfortable pace.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Label("Your Sa: \(PitchMath.nearestNote(vm.sa).name)", systemImage: "tuningfork")
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
            CentsMeter(cents: vm.cents)
            Text(vm.feedback)
                .font(.headline)
                .foregroundColor(vm.feedbackKind.color)
                .animation(.easeInOut(duration: 0.15), value: vm.feedback)
            ProgressView(value: vm.holdProgress)
                .tint(.swarGreen)
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
            Text("Follow the melody").font(.headline)
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
                Button { vm.finishEarly() } label: { Label("Stop practice", systemImage: "stop.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            } else if vm.phase == .idle {
                Button { vm.referencePlaying ? vm.stopReference() : vm.playReference() } label: {
                    Label(vm.referencePlaying ? "Stop reference" : "Listen first (optional)", systemImage: vm.referencePlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                .disabled(vm.isStarting || !vm.exerciseFitsRange)
                Button { vm.start() } label: { Label(vm.isStarting ? "Opening microphone…" : "Start Practice", systemImage: "mic.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!vm.canStart)
            }
        }
    }

    private var sequenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alankaar").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
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
        if result.practiceMatchPercent < 80 { return .needsAdjustment }
        return .onTarget
    }

    private var icon: String {
        if isCurrent { return "waveform" }
        guard let r = result else { return "circle" }
        if r.detectedHz == nil { return "minus.circle" }
        return r.practiceMatchPercent < 80 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(target.label).font(.headline)
            if let result = result {
                Text(String(format: "%.1f%%", result.practiceMatchPercent))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
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
