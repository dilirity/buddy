import Foundation
import ImageIO
import UniformTypeIdentifiers

// Sanity checks + PNG rendering for sprites.json, used by `Buddy --check` and
// `Buddy --render` so a mutation can't ship a visually broken buddy.
enum SpriteLint {
    static let requiredAnims = ["idle", "walk", "sleep", "held"]

    static func run(_ url: URL) -> [String] {
        var errors: [String] = []
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["sprites.json missing or not valid JSON"]
        }
        guard let palette = json["palette"] as? [String: String] else {
            return ["sprites.json: palette missing"]
        }
        var chars = Set<Character>()
        for (key, value) in palette {
            if key.count != 1 {
                errors.append("palette key \"\(key)\" must be a single character")
            } else {
                chars.insert(key.first!)
            }
            if value != "transparent" {
                let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
                if !(hex.count == 3 || hex.count == 6) || UInt32(hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex, radix: 16) == nil {
                    errors.append("palette \"\(key)\": bad color \"\(value)\"")
                }
            }
        }

        func lintRows(_ rows: [String], label: String) {
            guard let width = rows.first?.count, width > 0, !rows.isEmpty else {
                errors.append("\(label): empty pixel map")
                return
            }
            for (i, row) in rows.enumerated() {
                if row.count != width {
                    errors.append("\(label): row \(i) width \(row.count) != \(width) (ragged frame)")
                }
                for ch in row where !chars.contains(ch) {
                    errors.append("\(label): unknown palette char \"\(ch)\" in row \(i)")
                }
            }
        }

        guard let anims = json["anims"] as? [String: [String: Any]] else {
            return errors + ["sprites.json: anims missing"]
        }
        for name in requiredAnims where anims[name] == nil {
            errors.append("required anim \"\(name)\" missing - the shell triggers it directly")
        }
        for (name, spec) in anims {
            let fps = (spec["fps"] as? NSNumber)?.doubleValue ?? 4
            if fps <= 0 || fps > 30 {
                errors.append("anim \"\(name)\": fps \(fps) out of range (0, 30]")
            }
            guard let frames = spec["frames"] as? [[String]], !frames.isEmpty else {
                errors.append("anim \"\(name)\": no frames")
                continue
            }
            for (i, rows) in frames.enumerated() {
                lintRows(rows, label: "anim \"\(name)\" frame \(i)")
            }
        }
        if let props = json["props"] as? [String: [String]] {
            for (name, rows) in props {
                lintRows(rows, label: "prop \"\(name)\"")
            }
        }
        return errors
    }

    // Render every anim frame and every prop (composited on idle) to PNGs.
    static func render(to dir: URL) -> Bool {
        guard let sheet = SpriteLoader.load(from: BuddyPaths.sprites) else {
            print("FAIL: sprites.json did not load")
            return false
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scale = 8
        for (name, anim) in sheet.anims {
            for (i, frame) in anim.frames.enumerated() {
                writePNG(scaled(frame, by: scale), to: dir.appendingPathComponent("anim-\(name)-\(i).png"))
            }
        }
        let base = sheet.anims["idle"]?.frames.first
        for (name, prop) in sheet.props {
            let img = base.map { composite($0, over: prop) } ?? prop
            writePNG(scaled(img, by: scale), to: dir.appendingPathComponent("prop-\(name).png"))
        }
        print("rendered \(sheet.anims.count) anims + \(sheet.props.count) props to \(dir.path)")
        return true
    }

    private static func composite(_ base: CGImage, over prop: CGImage) -> CGImage {
        let w = max(base.width, prop.width), h = max(base.height, prop.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: h - base.height, width: base.width, height: base.height))
        ctx.draw(prop, in: CGRect(x: 0, y: h - prop.height, width: prop.width, height: prop.height))
        return ctx.makeImage() ?? base
    }

    private static func scaled(_ img: CGImage, by scale: Int) -> CGImage {
        let w = img.width * scale, h = img.height * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    private static func writePNG(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
