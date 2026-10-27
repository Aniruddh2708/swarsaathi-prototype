import SwiftUI
import UIKit

extension Color {
    static let swarBlue = Color(red: 0.25, green: 0.47, blue: 0.96)
    static let swarPurple = Color(red: 0.56, green: 0.36, blue: 0.92)
    static let swarBackground = Color(red: 0.97, green: 0.97, blue: 0.99)
    static let swarGreen = Color(red: 0.20, green: 0.70, blue: 0.45)
    static let swarOrange = Color(red: 0.96, green: 0.55, blue: 0.20)
}

extension Accuracy {
    var color: Color {
        switch self {
        case .veryAccurate: return .swarGreen
        case .onTarget: return .swarBlue
        case .needsAdjustment: return .swarOrange
        }
    }
}

extension FeedbackKind {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .perfect: return .swarGreen
        case .onTarget: return .swarBlue
        case .high, .low: return .swarOrange
        }
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(filled ? .white : .swarPurple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Group {
                    if filled {
                        LinearGradient(colors: [.swarBlue, .swarPurple], startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color.swarPurple.opacity(0.12)
                    }
                }
            )
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

func hzText(_ v: Double?) -> String {
    guard let v = v else { return "— Hz" }
    return String(format: "%.0f Hz", v)
}

struct LevelBar: View {
    let level: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [.swarBlue, .swarPurple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * CGFloat(level)))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 6)
    }
}

struct ErrorBanner: View {
    let message: String
    var showSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.swarOrange)
                Text(message).font(.subheadline)
            }
            if showSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.bold())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.swarOrange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Shows how far the voice is from the target: left = too low, centre = on target, right = too high.
struct CentsMeter: View {
    let cents: Double?
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let c = min(max(cents ?? 0, -150), 150)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(Color.swarGreen.opacity(0.25))
                        .frame(width: w / 3, height: 14)
                        .position(x: w / 2, y: 7)
                    if cents != nil {
                        Circle().fill(Color.swarBlue)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .position(x: w * CGFloat(0.5 + c / 300), y: 7)
                            .animation(.easeOut(duration: 0.12), value: c)
                    }
                }
            }
            .frame(height: 14)
            HStack {
                Text("Too low").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("On note").font(.caption2).foregroundColor(.swarGreen)
                Spacer()
                Text("Too high").font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}
