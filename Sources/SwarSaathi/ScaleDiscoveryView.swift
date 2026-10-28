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
                    Text("Find my Sa")
                        .font(.largeTitle.bold())
                    Text("Record three comfortable notes to find a Sa for practice.")
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
                    if vm.recommendation != nil {
                        saCard
                        Button {
                            showPractice = true
                        } label: {
                            Label("Start Alankaar Practice", systemImage: "music.note.list")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!vm.canPractice)
                    }
                    Button("Record all three again") { vm.retryCalibration() }
                        .disabled(vm.activeTest != nil || vm.isOpening)
                }
                if vm.auditURL != nil {
                    analysisCard
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
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 10) {
                analysisRow("Low", vm.low)
                analysisRow("Middle", vm.comfortable)
                analysisRow("High", vm.high)
                Text("Sa is a suggested starting note for this exercise, not a fixed personal scale.")
                    .font(.footnote).foregroundColor(.secondary)
                if let url = vm.auditURL {
                    ShareLink(item: url) { Label("Share report", systemImage: "square.and.arrow.up") }
                }
            }
            .padding(.top, 10)
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
            Label("Suggested Sa", systemImage: "tuningfork")
                .font(.headline)
            Text(PitchMath.nearestNote(vm.sa).name)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                startPoint: .leading, endPoint: .trailing))
            Text("Confirm if this feels comfortable for you.")
                .font(.subheadline).foregroundColor(.secondary)
            Button(vm.isReferencePlaying ? "Stop reference" : "Listen to Sa (optional)") {
                if vm.isReferencePlaying { vm.stopReference() } else { vm.playReference() }
            }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                .disabled(vm.isOpening || vm.activeTest != nil)
            Button(vm.isConfirmed ? "Sa confirmed" : "Confirm this Sa") { vm.confirmSa() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!vm.canConfirm || vm.isConfirmed)
            DisclosureGroup("Adjust Sa") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Adjust, then confirm again.").font(.footnote)
                    Text(hzText(vm.sa)).font(.subheadline)
                    HStack(spacing: 10) {
                        adjustButton("Lower") { vm.shiftSa(semitones: -1) }
                        adjustButton("Higher") { vm.shiftSa(semitones: 1) }
                    }
                    HStack(spacing: 10) {
                        adjustButton("Fine −1 Hz") { vm.nudgeSa(hz: -1) }
                        adjustButton("Fine +1 Hz") { vm.nudgeSa(hz: 1) }
                    }
                }
                .padding(.top, 8)
                .disabled(vm.isReferencePlaying || vm.isOpening || vm.activeTest != nil)
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
        if isActive { return "Finish recording" }
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
                    Text(vm.recordingStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    LevelBar(level: vm.level)
                }
            } else if saved != nil {
                Text("Recorded").font(.subheadline).foregroundColor(.swarGreen)
            }

            Button(buttonTitle) { vm.toggle(test) }
                .buttonStyle(PrimaryButtonStyle(filled: !(saved != nil && !isActive)))
                .disabled(!enabled)
        }
        .card()
        .opacity(vm.isUnlocked(test) ? 1 : 0.5)
    }
}
