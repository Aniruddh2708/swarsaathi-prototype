import SwiftUI

struct ScaleDiscoveryView: View {
    @ObservedObject var vm: ScaleViewModel
    let engine: PitchEngine
    @State private var showPractice = false

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
                    saCard
                    Button {
                        showPractice = true
                    } label: {
                        Label("Start Alankaar Practice", systemImage: "music.note.list")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.bottom, 24)
                }
            }
            .padding(20)
            .animation(.easeInOut, value: vm.isComplete)
        }
        .background(Color.swarBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showPractice) {
            PracticeView(sa: vm.sa, engine: engine)
        }
        .onDisappear { vm.stopIfNeeded() }
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
                    Text("Estimated vocal range").foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f octaves (%.0f semitones)", semis / 12, semis))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }
            if vm.orderLooksWrong {
                Text("Your low, comfortable and high notes aren't in rising order. You may want to record them again.")
                    .font(.footnote)
                    .foregroundColor(.swarOrange)
            }
            Text("This is your vocal range. It is not your musical scale; we use your comfortable note as Sa.")
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
            Text("Your Sa: \(Int(vm.sa)) Hz")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                startPoint: .leading, endPoint: .trailing))
            Text("Nearest musical note for reference: \(PitchMath.noteText(vm.sa)). Western note names don't define the Indian classical scale.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("Adjust if it doesn't feel right:")
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
    private var enabled: Bool { vm.isUnlocked(test) && (vm.activeTest == nil || isActive) }

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
                    Text(vm.liveFrequency == nil ? "Listening… sing and hold a steady note." : "Hold it steady, then tap Stop & Save.")
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
