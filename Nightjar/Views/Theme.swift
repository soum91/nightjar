import SwiftUI

enum Theme {
    static let accent = Color(red: 0.91, green: 0.64, blue: 0.24)
    static let bgTop = Color(red: 0.06, green: 0.07, blue: 0.13)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.5)
    static let good = Color(red: 0.42, green: 0.85, blue: 0.55)
    static let danger = Color(red: 1, green: 0.45, blue: 0.42)

    static func background(strength: Double = 0.16) -> some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(strength), .clear], center: .top, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cached remote image (signed URLs change every fetch, so key by event id when we have one).
struct RemoteImage: View {
    let url: String?
    var key: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
                Image(systemName: failed ? "photo" : "moon.stars")
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .task(id: key ?? url) { await load() }
    }

    private func load() async {
        let k = key ?? url ?? ""
        if let hit = ImageCache.shared.object(forKey: k as NSString) { image = hit; return }
        guard let s = url, let u = URL(string: s) else { failed = true; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: u)
            if let img = UIImage(data: data) {
                ImageCache.shared.setObject(img, forKey: k as NSString)
                image = img
            } else { failed = true }
        } catch { failed = true }
    }
}

enum ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}
