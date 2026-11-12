import SwiftUI

/// 話者アイコン：丸っこい形に白い目が 2 つ。`shape` で形（0..<shapeCount）を選ぶ。
struct BotAvatar: View {
    static let shapeCount = 8

    let shape: Int
    let color: Color
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            body(for: shape % Self.shapeCount)
                .foregroundStyle(color)
            eyes
        }
        .frame(width: size, height: size)
        // 雲や花は円の重ね合わせなので、1 枚に平らにしてから透明度をかける（重なりが濃く出ないように）。
        .compositingGroup()
    }

    @ViewBuilder
    private func body(for shape: Int) -> some View {
        switch shape {
        case 0: Circle().padding(size * 0.06)
        case 1: RoundedRectangle(cornerRadius: size * 0.18).padding(size * 0.14).rotationEffect(.degrees(-15))
        case 2: Cloud()
        case 3: // しずく：右上の角だけとがらせる
            UnevenRoundedRectangle(topLeadingRadius: size * 0.4, bottomLeadingRadius: size * 0.4,
                                   bottomTrailingRadius: size * 0.4, topTrailingRadius: size * 0.08)
                .padding(size * 0.1)
        case 4: Capsule().frame(height: size * 0.66).rotationEffect(.degrees(-8))
        case 5: // まるい石：横長で角の大きい四角を傾ける
            RoundedRectangle(cornerRadius: size * 0.3)
                .frame(width: size * 0.88, height: size * 0.72)
                .rotationEffect(.degrees(12))
        case 6: RoundedPolygon(sides: 6, cornerRadius: size * 0.12).padding(size * 0.06).rotationEffect(.degrees(10))
        default: Scallop().padding(size * 0.02)
        }
    }

    private var eyes: some View {
        HStack(spacing: size * 0.1) {
            Capsule().frame(width: size * 0.09, height: size * 0.22)
            Capsule().frame(width: size * 0.09, height: size * 0.22)
        }
        .foregroundStyle(.white)
        .rotationEffect(.degrees(-20))
        .offset(x: size * 0.1, y: -size * 0.1)
    }
}

/// 3 つの円を重ねた雲。
private struct Cloud: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle().frame(width: s * 0.62).offset(x: -s * 0.14, y: s * 0.06)
                Circle().frame(width: s * 0.58).offset(x: s * 0.16, y: -s * 0.08)
                Circle().frame(width: s * 0.5).offset(x: s * 0.14, y: s * 0.16)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// 花びらを 8 枚並べたふちのギザギザした形。
private struct Scallop: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle().frame(width: s * 0.7)
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) / 8 * 2 * .pi
                    Circle()
                        .frame(width: s * 0.32)
                        .offset(x: cos(angle) * s * 0.32, y: sin(angle) * s * 0.32)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// 角を丸めた正多角形。
private struct RoundedPolygon: Shape {
    var sides: Int
    var cornerRadius: CGFloat
    var rotation: Double = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let points = (0..<sides).map { i -> CGPoint in
            let a = Double(i) / Double(sides) * 2 * .pi - .pi / 2 + rotation - .pi / 2
            return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        }
        var path = Path()
        for i in 0..<sides {
            let prev = points[(i + sides - 1) % sides]
            let cur = points[i]
            let next = points[(i + 1) % sides]
            let start = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            if i == 0 { path.move(to: start) }
            path.addArc(tangent1End: cur, tangent2End: next, radius: cornerRadius)
        }
        path.closeSubpath()
        return path
    }
}

/// 話者分離ラベル（"1", "2", ...）ごとの色とアイコンの形。同じ番号はいつも同じ見た目。
/// アプリの字幕と HTML レポートで共有する。
struct VoiceStyle {
    /// 0...1 の RGB。
    let rgb: (Double, Double, Double)
    let shape: Int

    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255))
    }

    static let palette: [(Double, Double, Double)] = [
        (0.33, 0.71, 0.63), // teal
        (0.92, 0.45, 0.20), // orange
        (0.55, 0.36, 0.96), // purple
        (0.36, 0.74, 0.45), // green
        (0.90, 0.30, 0.60), // pink
        (0.26, 0.52, 0.96), // blue
        (0.90, 0.60, 0.23), // amber
        (0.58, 0.41, 0.25), // brown
    ]

    /// `speaker`：ハイブリッドの会議では「相手 1」と「話者 1」が同時に出るので、会場側（.room）は
    /// 4 つずらして見た目を分ける。
    init(voice: String, speaker: Speaker = .remote) {
        // Soniox は "1" 始まりの番号を返す。番号でなければ文字列から決める。
        let base = Int(voice).map { $0 - 1 } ?? voice.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let n = base + (speaker == .room ? 4 : 0)
        let index = ((n % Self.palette.count) + Self.palette.count) % Self.palette.count
        rgb = Self.palette[index]
        shape = index % BotAvatar.shapeCount
    }

    init(rgb: (Double, Double, Double), shape: Int) {
        self.rgb = rgb
        self.shape = shape
    }
}
