import SwiftUI

struct ScaleDiscoveryView: View {
    @ObservedObject var vm: ScaleViewModel
    let engine: PitchEngine
    @State private var showPractice = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Discover Your Scale")
                        .font(.largeTitle.bold())
                    Text("Let's understand your comfortable singing range.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let msg = vm.errorMessage {
                    ErrorBanner(message: msg, showSettings: vm.permissionDenied)
                }

                ForEach(ScaleViewModel.Test.allCases) { test in
                    TestCardView(test: test, vm: vm)
                }

                if vm.isComplete {
                    analysisCard
                    if vm.recommendation != nil { saCard }
                    Button {
                        showPractice = true
                    } label: {
                        Label("Start Alankaar Practice", systemImage: "music.note.list")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!vm.canPractice)
                    .padding(.bottom, 24)
                }
            }
            .padding(20)
            .animation(.easeInOut, value: vm.isComplete)
        }
        .background(Color.swarBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showPractice) {
            PracticeView(sa: vm.sa, engine: engine,
                         lowerHz: vm.recommendation?.lowerHz, upperHz: vm.recommendation?.upperHz)
        }
        .onAppear { vm.activate() }
        .onDisappear { vm.stopIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.activate() }
            else if phase == .background { vm.stopIfNeeded() }
        }
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Scale Analysis", systemImage: "chart.bar.xaxis")
                .font(.headline)
            analysisRow("Lowest pitch", vm.low)
            analysisRow("Comfortable pitch", vm.comfortable)
            analysisRow("Highest pitch", vm.high)
            if let semis = vm.rangeSemitones {
                Divider()
                HStack {
                    Text("Measured sample span").foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f octaves (%.0f semitones)", semis / 12, semis))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }
            if vm.orderLooksWrong {
                Text("The guided samples changed order. Reversals beyond their measured uncertainty require a retry; overlapping measurements can remain usable.")
                    .font(.footnote)
                    .foregroundColor(.swarOrange)
            }
            Text("Three short vowels only approximate a comfortable range. A trial Sa is fitted to the measured boundaries and the five-note exercise, then explicitly confirmed after listening.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .card()
    }

    private func analysisRow(_ title: String, _ hz: Double?) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            if let hz = hz {
                Text("\(hzText(hz)) · \(PitchMath.noteText(hz))").fontWeight(.semibold)
            }
        }
        .font(.subheadline)
    }

    private var saCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recommended Sa (tonic)", systemImage: "tuningfork")
                .font(.headline)
            Text("Trial Sa: \(String(format: "%.2f", vm.sa)) Hz")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                startPoint: .leading, endPoint: .trailing))
            Text("Nearest musical note for reference: \(PitchMath.noteText(vm.sa)). Western note names don't define the Indian classical scale.")
                .font(.footnote)
                .foregroundColor(.secondary)
            if let recommendation = vm.recommendation {
                Text(recommendation.explanation)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button(vm.isReferencePlaying ? "Playing suggested Sa…" : "Play suggested Sa") { vm.playReference() }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                .disabled(vm.isReferencePlaying || !vm.recordingControlsEnabled || vm.activeTest != nil)
            Button(vm.isConfirmed ? "Sa confirmed" : "Confirm this Sa") { vm.confirmSa() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!vm.canConfirm || vm.isConfirmed)
            Text("Adjust within the measured exercise boundaries, then listen and confirm again:")
                .font(.subheadline)
            HStack(spacing: 10) {
                adjustButton("−1 semitone") { vm.shiftSa(semitones: -1) }
                adjustButton("−1 Hz") { vm.nudgeSa(hz: -1) }
                adjustButton("+1 Hz") { vm.nudgeSa(hz: 1) }
                adjustButton("+1 semitone") { vm.shiftSa(semitones: 1) }
            }
        }
        .card()
    }

    private func adjustButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.swarPurple.opacity(0.12))
                .foregroundColor(.swarPurple)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct TestCardView: View {
    let test: ScaleViewModel.Test
    @ObservedObject var vm: ScaleViewModel

    private var isActive: Bool { vm.activeTest == test }
    private var saved: Double? { vm.results[test] }
    private var enabled: Bool { vm.recordingControlsEnabled && vm.isUnlocked(test) && (vm.activeTest == nil || isActive) }

    private var buttonTitle: String {
        if isActive { return "Stop & Save" }
        return saved == nil ? "Start Recording" : "Record Again"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: test.icon).foregroundColor(.swarPurple)
                Text(test.title).font(.headline)
                Spacer()
                if saved != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.swarGreen)
                }
            }
            Text(test.prompt)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if isActive {
                VStack(alignment: .leading, spacing: 8) {
                    Text(hzText(vm.liveFrequency))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundColor(vm.liveFrequency == nil ? .secondary : .swarBlue)
                    Text(vm.liveFrequency == nil ? "Listening… hold one comfortable steady Aa for about three seconds." : "Hold steady. The sample saves automatically after three seconds, or tap Stop & Save.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    LevelBar(level: vm.level)
                }
            } else if let s = saved {
                Text("Saved: \(hzText(s)) · \(PitchMath.noteText(s))")
                    .font(.title3.weight(.semibold))
            }

            Button(buttonTitle) { vm.toggle(test) }
                .buttonStyle(PrimaryButtonStyle(filled: !(saved != nil && !isActive)))
                .disabled(!enabled)
        }
        .card()
        .opacity(vm.isUnlocked(test) ? 1 : 0.5)
    }
}
