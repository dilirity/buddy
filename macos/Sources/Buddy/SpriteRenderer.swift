import AppKit

struct SpriteSheet {
    struct Anim {
        let fps: Double
        let frames: [CGImage]
        let loops: Bool
    }
    let anims: [String: Anim]
    let props: [String: CGImage]
    let pixelSize: CGSize
}

enum SpriteLoader {
    static func load(from url: URL) -> SpriteSheet? {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let paletteRaw = json["palette"] as? [String: String],
              let animsRaw = json["anims"] as? [String: [String: Any]] else { return nil }

        var palette: [Character: (UInt8, UInt8, UInt8, UInt8)] = [:]
        for (k, v) in paletteRaw {
            guard let ch = k.first else { continue }
            palette[ch] = parseColor(v)
        }

        var maxW = 0, maxH = 0
        var anims: [String: SpriteSheet.Anim] = [:]
        for (name, spec) in animsRaw {
            let fps = (spec["fps"] as? NSNumber)?.doubleValue ?? 4
            let loops = spec["loop"] as? Bool ?? true
            guard let framesRaw = spec["frames"] as? [[String]] else { continue }
            var frames: [CGImage] = []
            for rows in framesRaw {
                if let img = render(rows: rows, palette: palette) {
                    frames.append(img)
                    maxW = max(maxW, img.width)
                    maxH = max(maxH, img.height)
                }
            }
            if !frames.isEmpty {
                anims[name] = .init(fps: fps, frames: frames, loops: loops)
            }
        }
        guard !anims.isEmpty else { return nil }

        var props: [String: CGImage] = [:]
        if let propsRaw = json["props"] as? [String: [String]] {
            for (name, rows) in propsRaw {
                if let img = render(rows: rows, palette: palette) {
                    props[name] = img
                }
            }
        }
        return SpriteSheet(anims: anims, props: props, pixelSize: CGSize(width: maxW, height: maxH))
    }

    // Last-resort sheet so the shell survives a mutator that mangles sprites.json.
    static func fallback() -> SpriteSheet {
        let rows = [
            "KKKKKKKK",
            "KMMMMMMK",
            "KMWMMWMK",
            "KMMMMMMK",
            "KMWWWWMK",
            "KMMMMMMK",
            "KKKKKKKK",
        ]
        let palette: [Character: (UInt8, UInt8, UInt8, UInt8)] = [
            "K": (26, 26, 36, 255),
            "M": (255, 0, 255, 255),
            "W": (255, 255, 255, 255),
        ]
        let img = render(rows: rows, palette: palette)!
        let anim = SpriteSheet.Anim(fps: 1, frames: [img], loops: true)
        return SpriteSheet(anims: ["idle": anim], props: [:], pixelSize: CGSize(width: img.width, height: img.height))
    }

    static func parseColor(_ s: String) -> (UInt8, UInt8, UInt8, UInt8) {
        if s == "transparent" { return (0, 0, 0, 0) }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count >= 6, let v = UInt32(hex.prefix(6), radix: 16) else { return (255, 0, 255, 255) }
        return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff), 255)
    }

    static func render(rows: [String], palette: [Character: (UInt8, UInt8, UInt8, UInt8)]) -> CGImage? {
        let h = rows.count
        let w = rows.map { $0.count }.max() ?? 0
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let c = palette[ch], c.3 > 0 else { continue }
                let i = (y * w + x) * 4
                buf[i] = c.0; buf[i + 1] = c.1; buf[i + 2] = c.2; buf[i + 3] = c.3
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        return buf.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}
