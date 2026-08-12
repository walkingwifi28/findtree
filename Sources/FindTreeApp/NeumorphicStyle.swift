import SwiftUI

enum NeumorphicTheme {
    static func surface(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.16, green: 0.16, blue: 0.175)
        default:
            return Color(red: 224.0 / 255.0, green: 224.0 / 255.0, blue: 224.0 / 255.0)
        }
    }

    static func highlight(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.16)
        default:
            return Color.white.opacity(0.95)
        }
    }

    static func shadow(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color.black.opacity(0.72)
        default:
            return Color(red: 0.68, green: 0.68, blue: 0.68).opacity(0.62)
        }
    }
}

struct NeumorphicButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var cornerRadius: CGFloat = 12
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 9
    var forcePressed: Bool = false
    var preserveOpacityWhenForcedPressed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = NeumorphicTheme.surface(for: colorScheme)
        let highlight = NeumorphicTheme.highlight(for: colorScheme)
        let shadow = NeumorphicTheme.shadow(for: colorScheme)
        let isPressed = configuration.isPressed || forcePressed

        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                if isPressed {
                    shape.fill(
                        surface
                            .shadow(.inner(color: shadow.opacity(0.95), radius: 5, x: 4, y: 4))
                            .shadow(.inner(color: highlight, radius: 5, x: -4, y: -4))
                    )
                } else {
                    shape.fill(surface)
                }
            }
            .clipShape(shape)
            .shadow(
                color: isPressed ? .clear : highlight,
                radius: 7,
                x: -5,
                y: -5
            )
            .shadow(
                color: isPressed ? .clear : shadow,
                radius: 7,
                x: 5,
                y: 5
            )
            .foregroundStyle(isPressed ? .secondary : .primary)
            .opacity(isEnabled || isPressed ? 1 : 0.46)
            .animation(.easeOut(duration: 0), value: isPressed)
    }
}

struct NeumorphicPressSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let isPressed: Bool
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let distance: CGFloat
    let strength: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = NeumorphicTheme.surface(for: colorScheme)
        let highlight = NeumorphicTheme.highlight(for: colorScheme)
        let shadow = NeumorphicTheme.shadow(for: colorScheme)

        content
            .background {
                if isPressed {
                    shape.fill(
                        surface
                            .shadow(.inner(color: shadow.opacity(0.95), radius: 5, x: 4, y: 4))
                            .shadow(.inner(color: highlight, radius: 5, x: -4, y: -4))
                    )
                } else {
                    shape.fill(surface)
                }
            }
            .clipShape(shape)
            .shadow(
                color: isPressed ? .clear : highlight.opacity(strength),
                radius: shadowRadius,
                x: -distance,
                y: -distance
            )
            .shadow(
                color: isPressed ? .clear : shadow.opacity(strength),
                radius: shadowRadius,
                x: distance,
                y: distance
            )
            .foregroundStyle(isPressed ? .secondary : .primary)
            .animation(.easeOut(duration: 0), value: isPressed)
    }
}

struct NeumorphicRaisedModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let distance: CGFloat
    let strength: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = NeumorphicTheme.surface(for: colorScheme)

        content
            .background(shape.fill(surface))
            .clipShape(shape)
            .shadow(
                color: NeumorphicTheme.highlight(for: colorScheme).opacity(strength),
                radius: shadowRadius,
                x: -distance,
                y: -distance
            )
            .shadow(
                color: NeumorphicTheme.shadow(for: colorScheme).opacity(strength),
                radius: shadowRadius,
                x: distance,
                y: distance
            )
    }
}

struct NeumorphicInsetModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let strength: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(shape.fill(NeumorphicTheme.surface(for: colorScheme)))
            .clipShape(shape)
            .overlay {
                NeumorphicInsetOverlay(
                    cornerRadius: cornerRadius,
                    colorScheme: colorScheme,
                    strength: strength
                )
            }
    }
}

struct NeumorphicInsetOverlay: View {
    let cornerRadius: CGFloat
    let colorScheme: ColorScheme
    let strength: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape
                .stroke(NeumorphicTheme.shadow(for: colorScheme).opacity(strength), lineWidth: 10)
                .blur(radius: 7)
                .offset(x: -5, y: -5)

            shape
                .stroke(NeumorphicTheme.highlight(for: colorScheme).opacity(strength), lineWidth: 10)
                .blur(radius: 7)
                .offset(x: 5, y: 5)
        }
        .mask(shape)
        .allowsHitTesting(false)
    }
}

extension View {
    func neumorphicPressSurface(
        isPressed: Bool,
        cornerRadius: CGFloat = 16,
        shadowRadius: CGFloat = 8,
        distance: CGFloat = 6,
        strength: Double = 1
    ) -> some View {
        modifier(
            NeumorphicPressSurfaceModifier(
                isPressed: isPressed,
                cornerRadius: cornerRadius,
                shadowRadius: shadowRadius,
                distance: distance,
                strength: strength
            )
        )
    }

    func neumorphicRaised(
        cornerRadius: CGFloat = 16,
        shadowRadius: CGFloat = 8,
        distance: CGFloat = 6,
        strength: Double = 1
    ) -> some View {
        modifier(
            NeumorphicRaisedModifier(
                cornerRadius: cornerRadius,
                shadowRadius: shadowRadius,
                distance: distance,
                strength: strength
            )
        )
    }

    func neumorphicInset(
        cornerRadius: CGFloat = 18,
        strength: Double = 1
    ) -> some View {
        modifier(
            NeumorphicInsetModifier(
                cornerRadius: cornerRadius,
                strength: strength
            )
        )
    }
}
