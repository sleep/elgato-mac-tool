import AppKit

// Compiled together with Sources/ElgatoCaptureGUI/AppIconRenderer.swift by
// package-app.sh so the Finder icon matches the one the app draws at runtime.
//
//   export-icon <out.png> [--full-bleed]
let args = Array(CommandLine.arguments.dropFirst())
let out = args.first { !$0.hasPrefix("--") } ?? "icon.png"
let image = AppIconRenderer.makeIcon(fullBleed: args.contains("--full-bleed"))
guard let rep = image.representations.first as? NSBitmapImageRep,
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
