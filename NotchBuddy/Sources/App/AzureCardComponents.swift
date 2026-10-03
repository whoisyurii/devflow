import SwiftUI

// Adapted directly from Coucou’s GitHubStatRow and GitHubPRRowView.
struct AzureStatRow: View {
    let icon: String
    let iconColor: String
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: iconColor))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

func ciDot(_ ci: CIState) -> Color {
    switch ci {
    case .failure: return Color(hex: "#F4505E")
    case .pending: return Color(hex: "#F5A524")
    case .success: return Color(hex: "#22C55E")
    case .unknown: return Color.clear
    }
}

struct AzurePRRowView: View {
    let pr: PullRequest
    let showCI: Bool

    var body: some View {
        Button(action: {
            if let url = safeWebURL(pr.url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 5) {
                if showCI {
                    Circle()
                        .fill(ciDot(pr.ci))
                        .frame(width: 5, height: 5)
                        .opacity(pr.ci == .unknown ? 0 : 1)
                } else {
                    Spacer().frame(width: 5)
                }
                Text("#\(pr.id)")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#9398A1"))
                    .lineLimit(1)
                Text(pr.title)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if pr.draft {
                    Text("Draft")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
        }
        .buttonStyle(.plain)
    }
}
