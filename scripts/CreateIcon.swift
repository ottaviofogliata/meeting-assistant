import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bounds = NSRect(x: 60, y: 60, width: 904, height: 904)
NSColor(calibratedRed: 0.82, green: 0.22, blue: 0.19, alpha: 1).setFill()
NSBezierPath(roundedRect: bounds, xRadius: 206, yRadius: 206).fill()
NSColor.white.setFill()
for (index, height) in [130, 260, 410, 540, 360, 210, 110].enumerated() {
    let rect = NSRect(x: 247 + index * 77, y: (1024 - height) / 2, width: 39, height: height)
    NSBezierPath(roundedRect: rect, xRadius: 19.5, yRadius: 19.5).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
