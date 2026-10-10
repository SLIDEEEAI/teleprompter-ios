import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: url)
let image = NSBitmapImageRep(data: data)!
var bright = 0
for y in (image.pixelsHigh * 3 / 10)..<(image.pixelsHigh * 7 / 10) {
    for x in (image.pixelsWide / 10)..<(image.pixelsWide * 9 / 10) {
        let c = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        if c.redComponent > 0.7 && c.greenComponent > 0.7 && c.blueComponent > 0.7 { bright += 1 }
    }
}
print("Visible white text pixels: \(bright)")
if bright < 200 { fatalError("Preview is blank: no readable glyphs") }
