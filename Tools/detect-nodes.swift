import Foundation
import CoreGraphics
import ImageIO

let path = CommandLine.arguments[1]
let threshold = UInt8(CommandLine.arguments.count > 2 ? UInt8(CommandLine.arguments[2])! : 160)

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("load failed") }

let w = cg.width, h = cg.height
var gray = [UInt8](repeating: 0, count: w * h)
gray.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}
print("image \(w)x\(h)  threshold \(threshold)")

// Flood-fill connected components over the thresholded mask.
var label = [Int32](repeating: 0, count: w * h)
var next: Int32 = 0
struct Comp { var n = 0; var sx = 0; var sy = 0
              var minX = Int.max; var maxX = 0; var minY = Int.max; var maxY = 0 }
var comps: [Comp] = []
var stack: [Int] = []

for start in 0..<(w * h) where gray[start] >= threshold && label[start] == 0 {
    next += 1
    var c = Comp()
    stack.removeAll(keepingCapacity: true)
    stack.append(start)
    label[start] = next
    while let p = stack.popLast() {
        let x = p % w, y = p / w
        c.n += 1; c.sx += x; c.sy += y
        c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
        c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
        for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
            let q = ny * w + nx
            if gray[q] >= threshold && label[q] == 0 { label[q] = next; stack.append(q) }
        }
    }
    comps.append(c)
}

// A node is a small, compact, near-square blob. Text glyphs and hexagon
// outlines fail one of those tests.
let candidates = comps.filter { $0.n >= 20 }

print("components: \(comps.count)  node-shaped: \(candidates.count)")
let sorted = candidates
    .map { c -> (x: Double, y: Double, n: Int, d: Double, fill: Double, aspect: Double) in
        let bw = c.maxX - c.minX + 1, bh = c.maxY - c.minY + 1
        return (x: Double(c.sx) / Double(c.n), y: Double(c.sy) / Double(c.n),
                n: c.n, d: Double(bw + bh) / 2,
                fill: Double(c.n) / Double(bw * bh),
                aspect: Double(bw) / Double(bh))
    }
    .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
for (i, c) in sorted.enumerated() {
    print(String(format: "  %2d  x=%6.1f y=%6.1f  px=%5d  bbox=%.0f  fill=%.2f  aspect=%.2f",
                 i, c.x, c.y, c.n, c.d, c.fill, c.aspect))
}
