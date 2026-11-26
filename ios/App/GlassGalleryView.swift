#if DEBUG
import SwiftUI

/// A debug-only reference sheet for the Liquid Glass knobs, reachable with
/// `-glass-gallery`. Every sample sits over a colour swatch so refraction is
/// visible, not just the material tint.
@available(iOS 26.0, *)
struct GlassGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.system.rawValue
    @Namespace private var union
    @State private var merged = false

    private let swatch = LinearGradient(
        colors: [.pink, .orange, .yellow, .green, .cyan, .purple],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("MATERIAL") {
                        HStack(spacing: 8) {
                            chip("Regular", glass: .regular)
                            chip("Clear", glass: .clear)
                            chip("Identity", glass: .identity, dashed: true)
                        }
                    }

                    section("TINT") {
                        HStack(spacing: 8) {
                            chip("Purple tint", glass: .regular.tint(.purple.opacity(0.55)))
                            chip("Orange tint", glass: .clear.tint(.orange.opacity(0.5)))
                        }
                    }

                    section("SHAPES") {
                        HStack(spacing: 18) {
                            shapeSample("Capsule", shape: Capsule())
                            shapeSample("Circle", shape: Circle(), side: 68)
                            shapeSample("Rounded", shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .frame(maxWidth: .infinity)
                    }

                    section("GROUPING") {
                        GlassEffectContainer(spacing: 10) {
                            HStack(spacing: merged ? 4 : -16) {
                                orb(0)
                                orb(1)
                                orb(2)
                            }
                            .onTapGesture { withAnimation(.snappy(duration: 0.35)) { merged.toggle() } }
                        }
                        Text("Tap to merge / separate (GlassEffectContainer)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    section("BUTTON STYLES") {
                        HStack(spacing: 10) {
                            Button("Glass") {}
                                .buttonStyle(.glass)
                            Button("Prominent") {}
                                .buttonStyle(.glassProminent)
                        }
                    }

                    section("MOTION ONLY") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Interactive: press any glass sample")
                            Text("Transitions: .materialize / .matchedGeometry")
                            Text("Scroll edges: .soft / .hard / .automatic")
                            Text("Toolbar: sharedBackgroundVisibility(.hidden)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground)
            .navigationTitle("Liquid Glass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .preferredColorScheme(AppAppearance(stored: appearance).colorScheme)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chip(_ title: String, glass: Glass, dashed: Bool = false) -> some View {
        ZStack {
            Capsule().fill(swatch)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .glassEffect(glass, in: Capsule())
        }
        .frame(height: 54)
        .overlay {
            if dashed {
                Capsule().strokeBorder(
                    Color.secondary.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
        }
    }

    private func shapeSample<S: Shape>(_ title: String, shape: S, side: CGFloat? = nil) -> some View {
        VStack(spacing: 6) {
            ZStack {
                shape.fill(swatch)
                Text("Aa")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular, in: shape)
            }
            .frame(width: side ?? 96, height: side ?? 68)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func orb(_ index: Int) -> some View {
        ZStack {
            Circle().fill(swatch)
            Text("\(index + 1)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(width: 58, height: 58)
        .glassEffect(.regular.interactive(), in: Circle())
        .glassEffectID(index, in: union)
    }

}
#endif
