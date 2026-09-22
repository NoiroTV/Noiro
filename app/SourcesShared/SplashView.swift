import SwiftUI

/// Compact Noiro wordmark shared by authentication, onboarding, and navigation surfaces.
struct NoiroWordmark: View {
    var fontSize: CGFloat = 38

    var body: some View {
        HStack(spacing: fontSize * 0.18) {
            Image("NoiroMark")
                .resizable()
                .scaledToFit()
                .frame(width: fontSize * 1.05, height: fontSize * 1.05)
            Text("NOIRO")
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .tracking(fontSize * 0.08)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Noiro")
    }
}

/// Code-built obsidian backdrop used throughout launch. The restrained light
/// field and particles are decorative and automatically become static when the
/// system's Reduce Motion setting is enabled.
struct NoiroPrismaticBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    private static let particles: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.08, 0.19, 3, 0.25), (0.17, 0.74, 2, 0.22), (0.28, 0.34, 2, 0.18),
        (0.39, 0.87, 3, 0.20), (0.52, 0.16, 2, 0.24), (0.62, 0.68, 2, 0.16),
        (0.73, 0.27, 3, 0.18), (0.84, 0.80, 2, 0.22), (0.93, 0.43, 2, 0.18)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.008, green: 0.008, blue: 0.018)

                Ellipse()
                    .fill(Color.indigo.opacity(0.22))
                    .frame(width: proxy.size.width * 0.82, height: proxy.size.height * 0.58)
                    .blur(radius: 110)
                    .offset(
                        x: drifting && !reduceMotion ? proxy.size.width * 0.08 : -proxy.size.width * 0.08,
                        y: -proxy.size.height * 0.19
                    )

                Ellipse()
                    .fill(Color.purple.opacity(0.17))
                    .frame(width: proxy.size.width * 0.58, height: proxy.size.height * 0.48)
                    .blur(radius: 100)
                    .offset(
                        x: drifting && !reduceMotion ? -proxy.size.width * 0.20 : proxy.size.width * 0.18,
                        y: proxy.size.height * 0.24
                    )

                LinearGradient(
                    colors: [.clear, Color.cyan.opacity(0.055), .clear, Color.purple.opacity(0.065), .clear],
                    startPoint: drifting && !reduceMotion ? .topLeading : .bottomLeading,
                    endPoint: drifting && !reduceMotion ? .bottomTrailing : .topTrailing
                )
                .blendMode(.screen)

                ForEach(Array(Self.particles.enumerated()), id: \.offset) { index, particle in
                    Circle()
                        .fill(Color.white.opacity(particle.opacity))
                        .frame(width: particle.size, height: particle.size)
                        .shadow(color: index.isMultiple(of: 2) ? .blue.opacity(0.5) : .purple.opacity(0.45), radius: 7)
                        .position(
                            x: proxy.size.width * particle.x,
                            y: proxy.size.height * particle.y + (drifting && !reduceMotion ? (index.isMultiple(of: 2) ? -10 : 10) : 0)
                        )
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                drifting = true
            }
        }
    }
}

enum NoiroSplashPresentation: Equatable {
    case firstInstall
    case returning

    var showsTagline: Bool { self == .firstInstall }
}

/// Prismatic N launch identity. Fresh installs receive the complete reveal and
/// tagline; returning launches get a compact mark/wordmark beat. Reduce Motion
/// receives the same final frames with shorter, static timing.
struct SplashView: View {
    var presentation: NoiroSplashPresentation = .firstInstall
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markIn = false
    @State private var wordmarkIn = false
    @State private var taglineIn = false
    @State private var fadingOut = false

    private var markSize: CGFloat {
        #if os(tvOS)
        return presentation == .firstInstall ? 250 : 205
        #else
        return presentation == .firstInstall ? 150 : 126
        #endif
    }

    private var wordmarkSize: CGFloat {
        #if os(tvOS)
        return presentation == .firstInstall ? 48 : 43
        #else
        return presentation == .firstInstall ? 34 : 30
        #endif
    }

    var body: some View {
        ZStack {
            NoiroPrismaticBackdrop()

            VStack(spacing: presentation == .firstInstall ? 26 : 20) {
                Image("NoiroMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
                    .shadow(color: .blue.opacity(markIn ? 0.55 : 0), radius: 34)
                    .shadow(color: .purple.opacity(markIn ? 0.45 : 0), radius: 44)
                    .scaleEffect(markIn || reduceMotion ? 1 : 0.84)
                    .blur(radius: markIn || reduceMotion ? 0 : 18)
                    .opacity(markIn || reduceMotion ? 1 : 0)

                Text("NOIRO")
                    .font(.system(size: wordmarkSize, weight: .heavy, design: .rounded))
                    .tracking(wordmarkSize * 0.18)
                    .foregroundStyle(.white)
                    .opacity(wordmarkIn || reduceMotion ? 1 : 0)

                if presentation.showsTagline {
                    Text("YOUR MEDIA. BEAUTIFULLY YOURS.")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(2.8)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .opacity(taglineIn || reduceMotion ? 1 : 0)
                }
            }
            .padding(Theme.Space.screenInset)
        }
        .opacity(fadingOut ? 0 : 1)
        .onAppear(perform: run)
    }

    private func run() {
        if reduceMotion {
            markIn = true
            wordmarkIn = true
            taglineIn = presentation.showsTagline
            DispatchQueue.main.asyncAfter(deadline: .now() + (presentation == .firstInstall ? 0.72 : 0.42)) {
                finish(fadeDuration: 0.12)
            }
            return
        }

        let fullReveal = presentation == .firstInstall
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: fullReveal ? 0.82 : 0.42)) {
            markIn = true
        }
        withAnimation(.easeOut(duration: fullReveal ? 0.38 : 0.24).delay(fullReveal ? 0.32 : 0.16)) {
            wordmarkIn = true
        }
        if fullReveal {
            withAnimation(.easeOut(duration: 0.34).delay(0.62)) { taglineIn = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fullReveal ? 1.44 : 0.70)) {
            finish(fadeDuration: fullReveal ? 0.24 : 0.18)
        }
    }

    private func finish(fadeDuration: Double) {
        withAnimation(.easeIn(duration: fadeDuration)) { fadingOut = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.02) { onFinished() }
    }
}
