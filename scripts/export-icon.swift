import AppKit

// Compiled together with Sources/ElgatoCaptureGUI/AppIconRenderer.swift by
// package-app.sh so the Finder icon matches the one the app draws at runtime.
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let image = AppIconRenderer.makeIcon()
guard let rep = image.representations.first as? NSBitmapImageRep,
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
