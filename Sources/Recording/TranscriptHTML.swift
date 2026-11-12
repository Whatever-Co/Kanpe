import Foundation

/// 文字起こしを読みやすい 1 枚の HTML にする（外部リソースなし）。
/// 話題ごとの区切りと目次、話者アバター（アプリの `BotAvatar` と同じ形と色を SVG で描く）、自分の発言は右寄せ。
enum TranscriptHTML {
    static func render(title: String, startedAt: Date, lines: [SubtitleLine], topics: [Topic], notes: [String]) -> String {
        let sections = split(lines, by: topics)
        let speakers = speakerList(lines)
        let duration = lines.last.map { Int($0.startedAt.timeIntervalSince(startedAt) / 60) } ?? 0

        var html = """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <div class="page">
        <aside class="toc">
          <div class="brand">Kanpe</div>
          <nav>
        """
        for (i, section) in sections.enumerated() where section.topic != nil {
            html += "<a href=\"#t\(i)\"><span class=\"time\">\(clock(section.topic!.startedAt, seconds: false))</span>\(escape(section.topic!.title))</a>\n"
        }
        html += """
          </nav>
        </aside>
        <main>
        <header class="hero">
          <h1>\(escape(title))</h1>
          <div class="meta">\(dateLabel(startedAt)) ・ 約 \(max(duration, 1)) 分 ・ \(lines.count) 発言 ・ 話題 \(topics.count) 個</div>
          <div class="people">
        """
        for speaker in speakers {
            html += "<span class=\"person\">\(avatar(for: speaker, size: 22))\(escape(speaker.label))</span>"
        }
        html += "</div>\n"
        for note in notes { html += "<div class=\"note\">\(escape(note))</div>\n" }
        html += "</header>\n"

        for (i, section) in sections.enumerated() {
            html += "<section id=\"t\(i)\">\n"
            if let topic = section.topic {
                html += """
                <div class="topic">
                  <div class="topic-time">\(clock(topic.startedAt, seconds: false))</div>
                  <h2>\(escape(topic.title))</h2>
                  <p>\(escape(topic.summary))</p>
                </div>

                """
            }
            var previous: SubtitleLine?
            for line in section.lines {
                let continued = previous.map { $0.label == line.label && line.startedAt.timeIntervalSince($0.startedAt) < 90 } ?? false
                html += message(line, continued: continued)
                previous = line
            }
            html += "</section>\n"
        }
        html += "</main>\n</div>\n</body>\n</html>\n"
        return html
    }

    // MARK: - Pieces

    private struct Section {
        let topic: Topic?
        var lines: [SubtitleLine]
    }

    /// 話題の開始時刻で行を区切る。最初の話題より前の行は見出しなしの区間になる。
    private static func split(_ lines: [SubtitleLine], by topics: [Topic]) -> [Section] {
        var sections = [Section(topic: nil, lines: [])]
        var pending = topics[...]
        for line in lines {
            while let topic = pending.first, topic.startedAt <= line.startedAt {
                sections.append(Section(topic: topic, lines: []))
                pending = pending.dropFirst()
            }
            sections[sections.count - 1].lines.append(line)
        }
        return sections.filter { $0.topic != nil || !$0.lines.isEmpty }
    }

    private static func speakerList(_ lines: [SubtitleLine]) -> [SubtitleLine] {
        var seen = Set<String>()
        var result: [SubtitleLine] = []
        for line in lines where seen.insert(line.label).inserted { result.append(line) }
        return result.sorted { $0.label < $1.label }
    }

    private static func message(_ line: SubtitleLine, continued: Bool) -> String {
        let mine = line.speaker == .me
        let compact = line.original.hasSuffix("）") && line.original.contains("（×")
        var classes = ["msg"]
        if mine { classes.append("mine") }
        if continued { classes.append("cont") }
        if compact { classes.append("compact") }
        let style = self.style(for: line)
        var html = "<div class=\"\(classes.joined(separator: " "))\" style=\"--c: \(style.hex)\">"
        html += "<div class=\"av\">\(continued ? "" : avatar(for: line, size: 34))</div>"
        html += "<div class=\"body\">"
        if !continued {
            html += "<div class=\"who\"><b>\(escape(line.label))</b><span>\(clock(line.startedAt, seconds: true))</span></div>"
        }
        html += "<div class=\"bubble\"><div class=\"orig\">\(escape(line.original))</div>"
        if !line.translation.isEmpty {
            html += "<div class=\"tr\">\(escape(line.translation))</div>"
        }
        html += "</div></div></div>\n"
        return html
    }

    private static let meStyle = VoiceStyle(rgb: (0.36, 0.40, 0.46), shape: 0)

    private static func style(for line: SubtitleLine) -> VoiceStyle {
        if line.speaker == .me { return meStyle }
        if let voice = line.voice { return VoiceStyle(voice: voice, speaker: line.speaker) }
        return VoiceStyle(voice: "1")
    }

    // MARK: - Avatar SVG（BotAvatar と同じ形）

    private static func avatar(for line: SubtitleLine, size: Int) -> String {
        let style = self.style(for: line)
        let c = style.hex
        let shape: String
        switch style.shape % BotAvatar.shapeCount {
        case 0: shape = "<circle cx='50' cy='50' r='44' fill='\(c)'/>"
        case 1: shape = "<rect x='14' y='14' width='72' height='72' rx='18' fill='\(c)' transform='rotate(-15 50 50)'/>"
        case 2: shape = "<circle cx='36' cy='56' r='31' fill='\(c)'/><circle cx='66' cy='42' r='29' fill='\(c)'/><circle cx='64' cy='66' r='25' fill='\(c)'/>"
        case 3: shape = "<path d='M50 10 H82 Q90 10 90 18 V50 A40 40 0 0 1 50 90 A40 40 0 0 1 10 50 A40 40 0 0 1 50 10 Z' fill='\(c)'/>"
        case 4: shape = "<rect x='6' y='17' width='88' height='66' rx='33' fill='\(c)' transform='rotate(-8 50 50)'/>"
        case 5: shape = "<rect x='6' y='14' width='88' height='72' rx='30' fill='\(c)' transform='rotate(12 50 50)'/>"
        case 6:
            let points = (0..<6).map { i -> String in
                let a = Double(i) * .pi / 3 + .pi / 18
                return String(format: "%.1f,%.1f", 50 + cos(a) * 38, 50 + sin(a) * 38)
            }.joined(separator: " ")
            shape = "<polygon points='\(points)' fill='\(c)' stroke='\(c)' stroke-width='14' stroke-linejoin='round'/>"
        default:
            var petals = "<circle cx='50' cy='50' r='35' fill='\(c)'/>"
            for i in 0..<8 {
                let a = Double(i) / 8 * 2 * .pi
                petals += String(format: "<circle cx='%.1f' cy='%.1f' r='16' fill='%@'/>", 50 + cos(a) * 32, 50 + sin(a) * 32, c)
            }
            shape = petals
        }
        let eyes = "<g fill='#fff' transform='rotate(-20 60 40)'><rect x='46' y='29' width='9' height='22' rx='4.5'/><rect x='65' y='29' width='9' height='22' rx='4.5'/></g>"
        return "<svg class='avatar' width='\(size)' height='\(size)' viewBox='0 0 100 100' aria-hidden='true'>\(shape)\(eyes)</svg>"
    }

    // MARK: - Formatting

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let shortClockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E) HH:mm"
        return f
    }()

    private static func clock(_ date: Date, seconds: Bool) -> String {
        (seconds ? clockFormat : shortClockFormat).string(from: date)
    }

    private static func dateLabel(_ date: Date) -> String { dateFormat.string(from: date) }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root {
      --bg: #f5f3ee; --card: #ffffff; --ink: #1f2328; --sub: #6b7078; --line: #e6e2d9;
      --accent: #3f7d6e; --mine: #eef2f7;
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; scroll-padding-top: 16px; }
    body {
      margin: 0; background: var(--bg); color: var(--ink);
      font: 15px/1.75 -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    .page { display: grid; grid-template-columns: 240px minmax(0, 1fr); max-width: 1120px; margin: 0 auto; gap: 32px; padding: 32px 24px 96px; }
    .toc { position: sticky; top: 24px; align-self: start; max-height: calc(100vh - 48px); overflow: auto; }
    .brand { font-weight: 700; letter-spacing: .08em; color: var(--accent); font-size: 13px; margin-bottom: 12px; }
    .toc nav { display: flex; flex-direction: column; gap: 2px; border-left: 2px solid var(--line); }
    .toc a { color: var(--ink); text-decoration: none; font-size: 13px; line-height: 1.5; padding: 6px 10px; margin-left: -2px; border-left: 2px solid transparent; }
    .toc a:hover { border-left-color: var(--accent); background: #ebe7de; }
    .toc .time { display: block; color: var(--sub); font-size: 11px; font-variant-numeric: tabular-nums; }
    main { min-width: 0; }
    .hero { background: var(--card); border: 1px solid var(--line); border-radius: 18px; padding: 24px 28px; margin-bottom: 28px; }
    .hero { overflow-wrap: anywhere; }
    .hero h1 { margin: 0 0 4px; font-size: 24px; letter-spacing: .01em; }
    .meta { color: var(--sub); font-size: 13px; }
    .people { display: flex; flex-wrap: wrap; gap: 8px 16px; margin-top: 14px; }
    .person { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 600; }
    .note { overflow-wrap: anywhere; margin-top: 12px; font-size: 12px; color: #8a5a00; background: #fff6e0; border: 1px solid #f1dfae; border-radius: 10px; padding: 6px 10px; }
    section { margin-bottom: 36px; }
    .topic { position: sticky; top: 0; z-index: 2; background: color-mix(in srgb, var(--bg) 88%, transparent); backdrop-filter: blur(8px);
      padding: 14px 0 10px; margin-bottom: 8px; border-bottom: 1px solid var(--line); }
    .topic-time { color: var(--accent); font-size: 12px; font-weight: 700; font-variant-numeric: tabular-nums; }
    .topic h2 { margin: 0; font-size: 19px; }
    .topic p { margin: 2px 0 0; color: var(--sub); font-size: 13px; line-height: 1.6; }
    .msg { display: flex; gap: 10px; margin-top: 14px; }
    .msg.cont { margin-top: 4px; }
    .msg .av { flex: 0 0 34px; }
    .avatar { display: block; }
    .msg .body { min-width: 0; max-width: 78%; }
    .who { display: flex; gap: 8px; align-items: baseline; font-size: 12px; margin-bottom: 2px; }
    .who b { color: var(--c); }
    .who span { color: var(--sub); font-variant-numeric: tabular-nums; }
    .bubble { background: var(--card); border: 1px solid var(--line); border-radius: 4px 14px 14px 14px; padding: 8px 13px; }
    .orig { white-space: pre-wrap; overflow-wrap: anywhere; }
    .tr { margin-top: 4px; padding-top: 4px; border-top: 1px dashed var(--line); color: var(--sub); font-size: 14px; }
    .msg.mine { flex-direction: row-reverse; }
    .msg.mine .who { justify-content: flex-end; }
    .msg.mine .bubble { background: var(--mine); border-color: #dde3ec; border-radius: 14px 4px 14px 14px; }
    .msg.compact .bubble { background: transparent; border: none; padding: 0 2px; color: var(--sub); font-size: 13px; }
    .msg.mine.compact .body { text-align: right; }
    @media (max-width: 860px) {
      .page { grid-template-columns: minmax(0, 1fr); padding: 16px 16px 64px; gap: 16px; }
      .toc { position: static; max-height: none; }
      .toc nav { flex-direction: row; flex-wrap: wrap; border-left: none; gap: 6px; }
      .toc a { border: 1px solid var(--line); border-radius: 999px; margin: 0; background: var(--card); }
      .toc .time { display: inline; margin-right: 6px; }
      .msg .body { max-width: 86%; }
    }
    """
}
