/// Packed RGB rows of one frame, each converted the first time a reader asks
/// for it and kept for the frame's other readers. The gear and portal
/// checks read overlapping bands: at 603x1311, 432 of their 505 rows.
///
/// `begin` starts a frame and forgets every row, so nothing converted from
/// one frame's planes is ever handed out for another; `end` forgets them
/// too, so a reader that runs outside a frame converts afresh. The storage
/// is kept between frames and only grows. The window bounds it to the rows
/// the frame's readers will ask for; a request outside the window starts a
/// wider one, which costs a conversion but is never wrong.
struct ColorRowCache {
    /// Converts frame rows `rows` into packed RGB at the pointer.
    typealias Convert = (_ rows: Range<Int32>, _ into: UnsafeMutablePointer<UInt8>) -> Void

    private(set) var window: Range<Int32> = 0..<0
    private var width: Int32 = 0
    private var storage: [UInt8] = []
    /// Per window row, whether it holds this frame's conversion.
    private var converted: [Bool] = []

    /// A frame `width` pixels wide whose readers will ask for rows in
    /// `window`.
    mutating func begin(width: Int32, window: Range<Int32>) {
        self.width = max(0, width)
        self.window = window
        let count = Int(self.width) * window.count * 3
        if storage.count < count { storage = [UInt8](repeating: 0, count: count) }
        converted.removeAll(keepingCapacity: true)
        converted.append(contentsOf: repeatElement(false, count: window.count))
    }

    mutating func end() {
        window = 0..<0
        converted.removeAll(keepingCapacity: true)
    }

    /// `body` on rows `rows` of the current frame, `width * 3` bytes each,
    /// converting with `convert` the runs of them not converted yet. The
    /// pointer is valid only inside `body`. Nil for no rows.
    mutating func withRows<R>(_ rows: Range<Int32>, width: Int32, convert: Convert,
                              _ body: (UnsafePointer<UInt8>) -> R) -> R? {
        guard !rows.isEmpty, width > 0 else { return nil }
        if width != self.width || rows.lowerBound < window.lowerBound || rows.upperBound > window.upperBound {
            let wider = window.isEmpty || width != self.width
                ? rows : min(window.lowerBound, rows.lowerBound)..<max(window.upperBound, rows.upperBound)
            begin(width: width, window: wider)
        }
        let rowBytes = Int(width) * 3
        let first = Int(rows.lowerBound - window.lowerBound)
        storage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = first
            let last = first + rows.count
            while index < last {
                guard !converted[index] else { index += 1; continue }
                var runEnd = index + 1
                while runEnd < last, !converted[runEnd] { runEnd += 1 }
                let top = window.lowerBound + Int32(index)
                convert(top..<(top + Int32(runEnd - index)), base + index * rowBytes)
                for row in index..<runEnd { converted[row] = true }
                index = runEnd
            }
        }
        return storage.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { body($0 + first * rowBytes) }
        }
    }
}
