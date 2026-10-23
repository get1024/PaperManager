import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// This tool performs deterministic packaging only. The full-bleed artwork is
// retained unchanged in composition; all sizes share one macOS icon geometry.
private enum IconExportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

private let canvasSize = 1024
private let tileSize: CGFloat = 824
private let fileManager = FileManager.default
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func image(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconExportError.invalid("Cannot decode image: \(url.path)")
    }
    return image
}

private func context(size: Int, opaque: Bool = false) throws -> CGContext {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace, bitmapInfo: alpha.rawValue) else {
        throw IconExportError.invalid("Cannot allocate \(size) px image.")
    }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    return context
}

private func png(_ image: CGImage, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconExportError.invalid("Cannot write PNG: \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconExportError.invalid("Cannot finalize PNG: \(url.path)")
    }
}

private func scaled(_ image: CGImage, to size: Int, opaque: Bool = false) throws -> CGImage {
    let destination = try context(size: size, opaque: opaque)
    destination.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let output = destination.makeImage() else {
        throw IconExportError.invalid("Cannot render \(size) px image.")
    }
    return output
}

private func squircle(in rect: CGRect) -> CGPath {
    // A superellipse has a continuous tangent through its corner transitions.
    // The dense path remains smooth after the shared 1024 px raster is reduced.
    let path = CGMutablePath()
    let exponent = 2.0 / 4.5
    let steps = 1024
    for step in 0...steps {
        let angle = Double(step) * 2 * .pi / Double(steps)
        let c = cos(angle), s = sin(angle)
        let x = copysign(pow(abs(c), exponent), c)
        let y = copysign(pow(abs(s), exponent), s)
        let point = CGPoint(x: rect.midX + CGFloat(x) * rect.width / 2,
                            y: rect.midY + CGFloat(y) * rect.height / 2)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

private func macOSIcon(from master: CGImage) throws -> CGImage {
    let output = try context(size: canvasSize)
    let inset = (CGFloat(canvasSize) - tileSize) / 2
    let tile = CGRect(x: inset, y: inset, width: tileSize, height: tileSize)
    let path = squircle(in: tile)
    output.saveGState()
    output.setShadow(offset: CGSize(width: 0, height: -8), blur: 14,
                     color: CGColor(gray: 0, alpha: 0.16))
    output.addPath(path)
    output.setFillColor(CGColor(gray: 0, alpha: 1))
    output.fillPath()
    output.restoreGState()
    output.saveGState()
    output.addPath(path)
    output.clip()
    output.draw(master, in: tile)
    output.restoreGState()
    guard let icon = output.makeImage() else {
        throw IconExportError.invalid("Cannot render macOS icon.")
    }
    return icon
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func relativePath(_ url: URL, to root: URL) -> String {
    let prefix = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}

private func imageRecord(_ url: URL, root: URL) throws -> [String: Any] {
    let bitmap = try image(at: url)
    let rgba = try context(size: bitmap.width)
    rgba.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
    guard let bytes = rgba.data?.assumingMemoryBound(to: UInt8.self) else {
        throw IconExportError.invalid("Cannot check alpha: \(url.path)")
    }
    var transparentPixels = 0
    var translucentPixels = 0
    for index in 0..<(bitmap.width * bitmap.height) {
        let alpha = bytes[index * 4 + 3]
        if alpha == 0 { transparentPixels += 1 }
        else if alpha < 255 { translucentPixels += 1 }
    }
    return ["file": relativePath(url, to: root), "pixels": [bitmap.width, bitmap.height],
            "mode": "RGBA", "colorSpace": "sRGB", "sha256": try sha256(url),
            "transparentPixels": transparentPixels, "translucentPixels": translucentPixels]
}

private func export(sourceURL: URL, outputRoot: URL, projectRoot: URL) throws {
    let source = try image(at: sourceURL)
    guard source.width == source.height, source.width >= canvasSize else {
        throw IconExportError.invalid("Expected a square, full-bleed source of at least 1024 px; got \(source.width)×\(source.height).")
    }
    let master = try scaled(source, to: canvasSize, opaque: true)
    let tile = try macOSIcon(from: master)
    let masterURL = outputRoot.appendingPathComponent("App/IconSource/AppIcon-1024.png")
    try png(master, to: masterURL)

    let assetDirectory = outputRoot.appendingPathComponent("Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset")
    let iconset = outputRoot.appendingPathComponent("PaperManager.iconset")
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    var exports: [[String: Any]] = []
    for pointSize in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let size = pointSize * scale
            let suffix = scale == 1 ? "" : "@2x"
            let assetURL = assetDirectory.appendingPathComponent("AppIcon-\(pointSize)\(suffix).png")
            try png(try scaled(tile, to: size), to: assetURL)
            let record = try imageRecord(assetURL, root: outputRoot)
            guard (record["pixels"] as? [Int]) == [size, size],
                  (record["transparentPixels"] as? Int ?? 0) > 0 else {
                throw IconExportError.invalid("Invalid icon export: \(assetURL.path)")
            }
            exports.append(record)
            let iconsetURL = iconset.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png")
            try fileManager.copyItem(at: assetURL, to: iconsetURL)
        }
    }
    let readmeURL = outputRoot.appendingPathComponent("docs/images/app-icon.png")
    try png(try scaled(tile, to: 256), to: readmeURL)
    exports.append(try imageRecord(readmeURL, root: outputRoot))
    let masterRecord: [String: Any] = ["file": relativePath(masterURL, to: outputRoot),
                                       "pixels": [canvasSize, canvasSize], "mode": "RGB",
                                       "colorSpace": "sRGB", "sha256": try sha256(masterURL)]
    let icnsURL = outputRoot.appendingPathComponent("App/PaperManager.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", iconset.path, "--output", icnsURL.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0,
          try Data(contentsOf: icnsURL).prefix(4) == Data("icns".utf8) else {
        throw IconExportError.invalid("iconutil could not create a valid ICNS file.")
    }
    try fileManager.removeItem(at: iconset)
    let sourceAlpha = source.alphaInfo
    let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(sourceAlpha)
    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "source": ["file": relativePath(sourceURL, to: projectRoot),
                   "pixels": [source.width, source.height], "mode": hasAlpha ? "RGBA" : "RGB",
                   "sha256": try sha256(sourceURL)],
        "master": masterRecord,
        "geometry": ["canvasPixels": canvasSize, "tilePixels": Int(tileSize),
                     "tileInsetPixels": Int((CGFloat(canvasSize) - tileSize) / 2),
                     "shape": "superellipse", "superellipseExponent": 4.5,
                     "shadowOffsetPixels": [0, -8], "shadowBlurPixels": 14, "shadowOpacity": 0.16],
        "exports": exports,
        "icns": ["file": relativePath(icnsURL, to: outputRoot), "sha256": try sha256(icnsURL)],
        "generatorSHA256": ["scripts/render-app-icon.sh": try sha256(projectRoot.appendingPathComponent("scripts/render-app-icon.sh")),
                            "scripts/tools/RenderAppIcon.swift": try sha256(projectRoot.appendingPathComponent("scripts/tools/RenderAppIcon.swift"))],
        "validation": "All ten AppIcon PNG dimensions and transparent canvas were checked; ICNS was compiled by macOS iconutil. Artwork composition is unchanged across sizes."
    ]
    let manifestURL = outputRoot.appendingPathComponent("App/IconSource/manifest.json")
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data([10])).write(to: manifestURL)
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw IconExportError.invalid("Expected source-image, output-root and project-root arguments.")
    }
    try export(sourceURL: URL(fileURLWithPath: CommandLine.arguments[1]),
               outputRoot: URL(fileURLWithPath: CommandLine.arguments[2]),
               projectRoot: URL(fileURLWithPath: CommandLine.arguments[3]))
} catch {
    fputs("Icon export failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
