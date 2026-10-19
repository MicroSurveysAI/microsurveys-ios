//
//  GoogleFontLoader.swift
//  MicroSurveysSDK
//
//  Fetches a dashboard-selected Google Font at runtime and registers it with the
//  process font manager — IN MEMORY ONLY. Fonts are never bundled in the SDK and
//  never written to disk; each launch re-fetches on demand. The set mirrors the
//  dashboard font picker. Used by `applyCachedTheme()` when `theme.font` names a
//  font that isn't already available on the device.
//

#if canImport(UIKit)
import UIKit
import CoreText

enum GoogleFontLoader {

    /// Fonts the dashboard offers — keep in sync with the dashboard picker.
    static let supportedFamilies = [
        "Inter", "Roboto", "Open Sans", "Noto Sans", "Lato", "Montserrat", "Poppins",
    ]

    /// Families currently downloading, to coalesce duplicate requests. Main-thread only.
    private static var inFlight = Set<String>()

    /// Downloads the Regular (400) + SemiBold (600) faces of `family` from Google
    /// Fonts and registers them in memory. `completion(true)` on the main thread if
    /// at least one face registered; `false` on any failure (caller keeps system font).
    static func load(family: String, completion: @escaping (Bool) -> Void) {
        guard supportedFamilies.contains(family) else { completion(false); return }

        DispatchQueue.main.async {
            guard !inFlight.contains(family) else { completion(false); return }
            inFlight.insert(family)

            let encoded = family.replacingOccurrences(of: " ", with: "+")
            guard let cssURL = URL(string:
                "https://fonts.googleapis.com/css2?family=\(encoded):wght@400;600&display=swap") else {
                finish(family, false, completion); return
            }

            var request = URLRequest(url: cssURL)
            // A non-woff2 User-Agent makes Google serve plain TTF, which CoreText can register.
            request.setValue("Wget/1.20", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: request) { data, _, error in
                guard let data, let css = String(data: data, encoding: .utf8) else {
                    MSLog.debug("GoogleFontLoader: CSS fetch failed for '\(family)' (\(error?.localizedDescription ?? "no data"))")
                    finish(family, false, completion); return
                }
                let urls = ttfURLs(inCSS: css)
                guard !urls.isEmpty else {
                    MSLog.debug("GoogleFontLoader: no TTF urls in CSS for '\(family)'")
                    finish(family, false, completion); return
                }
                downloadAndRegister(urls: urls) { count in
                    MSLog.debug("GoogleFontLoader: registered \(count)/\(urls.count) face(s) for '\(family)'")
                    finish(family, count > 0, completion)
                }
            }.resume()
        }
    }

    private static func finish(_ family: String, _ ok: Bool, _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            inFlight.remove(family)
            completion(ok)
        }
    }

    /// Extracts `.ttf` URLs from the CSS `src:` declarations.
    private static func ttfURLs(inCSS css: String) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: "url\\((https://[^)]+?\\.ttf)\\)") else {
            return []
        }
        let ns = css as NSString
        return re.matches(in: css, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? URL(string: ns.substring(with: $0.range(at: 1))) : nil
        }
    }

    /// Downloads each TTF and registers it as an in-memory `CGFont`. Calls back with
    /// the number successfully registered.
    private static func downloadAndRegister(urls: [URL], done: @escaping (Int) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var count = 0
        for url in urls {
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                guard let data,
                      let provider = CGDataProvider(data: data as CFData),
                      let cgFont = CGFont(provider) else { return }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterGraphicsFont(cgFont, &error) {
                    lock.lock(); count += 1; lock.unlock()
                } else {
                    // Duplicate registration (already loaded) lands here and is harmless.
                    error?.release()
                }
            }.resume()
        }
        group.notify(queue: .main) { done(count) }
    }
}
#endif
