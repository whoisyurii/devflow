import SwiftUI

// Coucou’s top-centred island container, shape animation, spacing and header.
// Unrelated chat/upload flows are removed; details stay inside the same island.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state).frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

struct IslandContainer: View {
    @ObservedObject var state: AppState
    @State private var islandWidth = IslandConst.notchWidth
    @State private var islandHeight = IslandConst.notchHeight
    @State private var cornerRadius = IslandConst.roundedCorner
    private let openSpring = Animation.spring(response: 0.28, dampingFraction: 0.9)
    private let closeEase = Animation.easeOut(duration: 0.16)
    private var targetSize: CGSize {
        let (width, height) = islandSize(mode: state.mode, view: state.view, nw: state.notchWidth, nh: state.notchHeight)
        return CGSize(width: width, height: height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            IslandShape(width: islandWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: 0).fill(Color.black)
            if state.mode == .expanded {
                IslandContentView(state: state)
                    // Keep list/text layout stable while the outer island morphs.
                    .frame(width: IslandConst.expandedWidth, height: state.view == .overview ? 160 : 360)
                    .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                          cornerRadius: cornerRadius, topRadius: 0))
                    .transition(.opacity)
            } else if state.mode == .compact {
                PillSymbol(task: state.focusTask)
                    .frame(width: 22, height: 22)
                    .position(x: 40, y: islandHeight / 2)
                CompactMiniGrid(state: state)
                    .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                    .position(x: islandWidth - 40, y: islandHeight / 2)
                    .transition(.opacity)
            }
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        .onAppear { resize() }
        .onChange(of: targetSize) { _, _ in
            withAnimation(state.mode == .expanded ? openSpring : closeEase) { resize() }
        }
    }
    private func resize() {
        (islandWidth, islandHeight) = islandSize(mode: state.mode, view: state.view,
                                                nw: state.notchWidth, nh: state.notchHeight)
        cornerRadius = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
    }
}

struct IslandContentView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state).frame(height: 34)
            ZStack {
                if state.view == .overview {
                    OverviewView(state: state).frame(height: 98)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if state.view == .answer {
                    SessionAnswerView(state: state).transition(.opacity)
                } else {
                    WorkflowDetailView(state: state).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: state.view)
        }
        .padding(.top, 8).padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
    }
}

struct IslandHeader: View {
    @ObservedObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                TabButton(icon: "house.fill", isOn: state.view == .overview, label: "Home") {
                    state.view = .overview; state.latestNotice = nil; state.isPinned = false
                }
                TabButton(icon: "tray.fill", isOn: state.section == .inbox && state.view == .detail, label: "Inbox") {
                    state.show(.inbox)
                }
                Menu {
                    Button("Codex only") { BridgeModel.shared.selectAgent("codex") }
                    Button("Claude Code only") { BridgeModel.shared.selectAgent("claude") }
                    Button("Both agents") { BridgeModel.shared.selectAgent("both") }
                } label: {
                    Text(state.snapshot.settings.agentProvider == "both" ? "Agents" : state.snapshot.settings.agentProvider == "codex" ? "Codex" : "Claude Code")
                        .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose visible AI agent")
            }.padding(.leading, 14)
            Spacer()
            HStack(spacing: 14) {
                Button { BridgeModel.shared.perform(state.snapshot.connection == "disconnected" ? "connect" : "refresh") } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }.help("Refresh Azure DevOps").accessibilityLabel("Refresh Azure DevOps")
                Button { state.isPinned.toggle() } label: {
                    Image(systemName: state.isPinned ? "pin.fill" : "pin").font(.system(size: 13))
                }.help("Pin notch open").accessibilityLabel("Pin notch open")
                Button {
                    NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    openSettings()
                } label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .help("Settings").accessibilityLabel("Settings")
                Button { NotificationCenter.default.post(name: .islandCollapse, object: nil) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 11))
                }.help("Collapse notch").accessibilityLabel("Collapse notch")
            }
            .foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain).padding(.trailing, 16)
        }.frame(maxHeight: .infinity)
    }
}

// Retained Coucou capsule tab treatment.
struct TabButton: View {
    let icon: String
    let isOn: Bool
    let label: String
    let action: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(isOn ? Color(hex: "#1D1F23") : isHovered ? Color.white.opacity(0.07) : Color.clear)
                .clipShape(Capsule())
        }.buttonStyle(.plain).onHover { isHovered = $0 }.accessibilityLabel(label)
    }
}

struct CompactMiniGrid: View {
    @ObservedObject var state: AppState
    var body: some View {
        let cols = [GridItem(.fixed(12), spacing: 4), GridItem(.fixed(12), spacing: 4)]
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(state.tasks.filter { $0.id != state.focusId }) { task in
                PillSymbol(task: task).frame(width: 12, height: 12)
            }
        }.frame(width: 28, height: 28)
    }
}

// Original artwork is separately licensed; source icons occupy the same layout slots.
struct PillSymbol: View {
    let task: AgentTask
    var body: some View {
        GeometryReader { proxy in
            Image(systemName: task.symbol)
                .font(.system(size: max(7, proxy.size.width * 0.5), weight: .medium))
                .foregroundColor(Color(hex: task.color))
                .symbolEffect(.pulse, isActive: task.state == .working)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityHidden(true)
    }
}
