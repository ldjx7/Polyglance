import AppKit
import SwiftUI

struct ProviderBrandIcon: View {
    let provider: String
    var size: CGFloat = 16

    private var normalizedProvider: String {
        let cleaned = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        case "free-ai", "freeai", "official-ai", "polyglance-ai":
            return "free-ai"
        case "microsoft", "ms":
            return "microsoft"
        case "google":
            return "google"
        case "deepl":
            return "deepl"
        case "baidu":
            return "baidu"
        case "youdao":
            return "youdao"
        case "volcano", "volcengine":
            return "volcano"
        case "openai", "openai-compatible", "openaicompatible":
            return "openai"
        default:
            if cleaned.starts(with: "custom") {
                return "openai"
            }
            return cleaned
        }
    }

    private var loadedImage: NSImage? {
        let name = normalizedProvider
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderIcons") {
            return NSImage(contentsOf: bundleURL)
        }
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: bundleURL)
        }
        for dir in ["apps/macos/Resources/ProviderIcons", "Resources/ProviderIcons", "../Resources/ProviderIcons"] {
            let path = "\(dir)/\(name).png"
            if FileManager.default.fileExists(atPath: path) {
                return NSImage(contentsOfFile: path)
            }
        }
        if name == "free-ai" {
            if let appIcon = NSImage(named: "PolyglanceIcon") ?? NSApp.applicationIconImage {
                return appIcon
            }
        }
        return nil
    }

    var body: some View {
        if let img = loadedImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.2)))
        } else {
            fallbackIcon
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        switch normalizedProvider {
        case "free-ai":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case "microsoft":
            let gap = size * 0.08
            let tile = (size - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.95, green: 0.31, blue: 0.13)).frame(width: tile, height: tile)
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.50, green: 0.73, blue: 0.00)).frame(width: tile, height: tile)
                }
                HStack(spacing: gap) {
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.00, green: 0.64, blue: 0.94)).frame(width: tile, height: tile)
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 1.00, green: 0.73, blue: 0.00)).frame(width: tile, height: tile)
                }
            }
            .frame(width: size, height: size)
        case "google":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(red: 0.10, green: 0.45, blue: 0.91))
                Text("G")
                    .font(.system(size: size * 0.6, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case "deepl":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(red: 0.06, green: 0.17, blue: 0.27))
                Text("D")
                    .font(.system(size: size * 0.6, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case "youdao":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(red: 0.89, green: 0.15, blue: 0.11))
                Text("有道")
                    .font(.system(size: size * 0.38, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case "baidu":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(red: 0.16, green: 0.20, blue: 0.88))
                Image(systemName: "b.circle.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case "volcano":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(red: 0.0, green: 0.40, blue: 1.0))
                Image(systemName: "flame.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case "openai":
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(red: 0.06, green: 0.64, blue: 0.50))
                Image(systemName: "cpu")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        default:
            Image(systemName: "character.bubble")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.blue)
                .frame(width: size, height: size)
        }
    }
}
