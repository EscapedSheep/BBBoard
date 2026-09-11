import Foundation

/// 时间表述 → 日期的规则解析器。纯函数、确定性。
/// 中文规则自写（今天/明天/后天/大后天、N天后、周X/下周X、X月X日、M/D），
/// 英文交给 NSDataDetector（tomorrow / next Friday 等）。
/// 解析失败返回 nil——不猜测。
public enum DateResolver {
    /// 在文本中查找可解析的时间表述，返回（日期, 原文区间）。日期按自然日 0 点返回。
    public static func resolveWithRange(
        _ text: String,
        now: Date,
        calendar: Calendar = .current
    ) -> (date: Date, range: Range<String.Index>)? {
        if let hit = resolveChinese(text, now: now, calendar: calendar) {
            return hit
        }
        return resolveWithDetector(text, now: now, calendar: calendar)
    }

    public static func resolve(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        resolveWithRange(text, now: now, calendar: calendar)?.date
    }

    // MARK: - 中文规则

    private static func resolveChinese(
        _ text: String,
        now: Date,
        calendar: Calendar
    ) -> (date: Date, range: Range<String.Index>)? {
        // 注意顺序：更长的词优先（大后天 ⊃ 后天，下周X ⊃ 周X）。
        // 每个模式允许“前/之前/以前”后缀（“周五前把测试跑完”）。
        let suffix = "(?:之前|以前|前)?"
        let patterns: [String] = [
            "大后天" + suffix, "后天" + suffix, "(?:明天|明日)" + suffix, "(?:今天|今日)" + suffix,
            "[0-9０-９一二三四五六七八九十]+天后",
            "下周[一二三四五六日天]" + suffix,
            "(?:周|星期|礼拜)[一二三四五六日天]" + suffix,
            "[0-9０-９]{1,2}月[0-9０-９]{1,2}[日号]" + suffix,
            "[0-9０-９]{1,2}/[0-9０-９]{1,2}" + suffix
        ]
        // 取文本中最先出现的时间表述（“周五前交初稿，明天先对齐”→ 周五）；位置相同再按上面的模式优先级
        let fullRange = NSRange(text.startIndex..., in: text)
        var best: (date: Date, range: Range<String.Index>, location: Int)?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                guard let range = Range(match.range, in: text),
                      let date = interpretChinese(String(text[range]), now: now, calendar: calendar)
                else { continue }
                if let current = best, match.range.location >= current.location { break }
                best = (date, range, match.range.location)
                break // 同一模式取最先匹配，后续匹配位置更靠后不更优
            }
        }
        return best.map { ($0.date, $0.range) }
    }

    private static func interpretChinese(_ word: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        // 剥离“前/之前/以前”后缀（“周五前”→“周五”）
        var word = word
        for suffix in ["之前", "以前", "前"] where word.hasSuffix(suffix) {
            word = String(word.dropLast(suffix.count))
            break
        }
        switch word {
        case "今天", "今日": return today
        case "明天", "明日": return calendar.date(byAdding: .day, value: 1, to: today)
        case "后天": return calendar.date(byAdding: .day, value: 2, to: today)
        case "大后天": return calendar.date(byAdding: .day, value: 3, to: today)
        default: break
        }

        // N 天后
        if word.hasSuffix("天后") {
            let digits = String(word.dropLast(2))
            if let n = Int(digits) ?? chineseNumeral(digits) {
                return calendar.date(byAdding: .day, value: n, to: today)
            }
            return nil
        }

        // 下周X：下一个自然周的该星期几
        if word.hasPrefix("下周"), let weekday = weekdayFromChinese(word) {
            return weekdayInNextWeek(weekday, now: now, calendar: calendar)
        }
        // 周X / 星期X / 礼拜X（必须有星期前缀——“9月5日”的“日”不算）：下一个该星期几（含今天）
        if word.hasPrefix("周") || word.hasPrefix("星期") || word.hasPrefix("礼拜"),
           let weekday = weekdayFromChinese(word)
        {
            return nextWeekday(weekday, from: now, calendar: calendar, includingToday: true)
        }

        // X月X日 / X月X号：今年，已过则明年。月日须合法（1-12 / 1-31），不靠 Calendar 归一化
        if let match = try? NSRegularExpression(pattern: "([0-9０-９]{1,2})月([0-9０-９]{1,2})[日号]")
            .firstMatch(in: word, range: NSRange(word.startIndex..., in: word)),
           let monthRange = Range(match.range(at: 1), in: word),
           let dayRange = Range(match.range(at: 2), in: word),
           let month = Int(fullWidthDigits(String(word[monthRange]))),
           let day = Int(fullWidthDigits(String(word[dayRange])))
        {
            return monthDayDate(month: month, day: day, today: today, calendar: calendar)
        }

        // M/D（“9/5 前交报告”）：同上，今年，已过则明年
        if let match = try? NSRegularExpression(pattern: "^([0-9０-９]{1,2})/([0-9０-９]{1,2})$")
            .firstMatch(in: word, range: NSRange(word.startIndex..., in: word)),
           let monthRange = Range(match.range(at: 1), in: word),
           let dayRange = Range(match.range(at: 2), in: word),
           let month = Int(fullWidthDigits(String(word[monthRange]))),
           let day = Int(fullWidthDigits(String(word[dayRange])))
        {
            return monthDayDate(month: month, day: day, today: today, calendar: calendar)
        }

        return nil
    }

    private static func monthDayDate(month: Int, day: Int, today: Date, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: today)
        var components = DateComponents(year: year, month: month, day: day)
        guard var date = calendar.date(from: components),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day
        else { return nil }
        if date < today {
            components.year = year + 1
            guard let next = calendar.date(from: components) else { return nil }
            date = next
        }
        return date
    }

    private static func weekdayFromChinese(_ word: String) -> Int? {
        guard let last = word.last else { return nil }
        // Gregorian weekday：周日 = 1，周一 = 2 … 周六 = 7
        switch last {
        case "日", "天": return 1
        case "一": return 2
        case "二": return 3
        case "三": return 4
        case "四": return 5
        case "五": return 6
        case "六": return 7
        default: return nil
        }
    }

    private static func nextWeekday(_ weekday: Int, from now: Date, calendar: Calendar, includingToday: Bool) -> Date {
        let today = calendar.startOfDay(for: now)
        let current = calendar.component(.weekday, from: today)
        var delta = (weekday - current + 7) % 7
        if delta == 0 && !includingToday { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: today)!
    }

    private static func weekdayInNextWeek(_ weekday: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else {
            return nextWeekday(weekday, from: now, calendar: calendar, includingToday: false)
        }
        let nextWeekStart = week.end
        let startWeekday = calendar.component(.weekday, from: nextWeekStart)
        let delta = (weekday - startWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: nextWeekStart)!
    }

    private static func chineseNumeral(_ string: String) -> Int? {
        let map: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        // 含“十”的组合（十/十五/二十/二十五，至 99）
        if string.contains("十") {
            let parts = string.split(separator: "十", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            var digits: [Int] = []
            for part in parts {
                if part.isEmpty { continue }
                guard part.count == 1, let digit = map[part.first!] else { return nil }
                digits.append(digit)
            }
            let tens = parts[0].isEmpty ? 1 : digits.first
            let ones = parts[1].isEmpty ? 0 : digits.last
            guard let tens, let ones else { return nil }
            let value = tens * 10 + ones
            return value > 0 ? value : nil
        }
        // 无“十”：逐位数字（“三”→3；多位按位拼接，保留旧行为）
        var value = 0
        for char in string {
            guard let digit = map[char] else { return nil }
            value = value * 10 + digit
        }
        return value > 0 ? value : nil
    }

    private static func fullWidthDigits(_ string: String) -> String {
        String(string.map { char in
            guard let scalar = char.unicodeScalars.first,
                  scalar.value >= 0xFF10, scalar.value <= 0xFF19
            else { return char }
            return Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
        })
    }

    // MARK: - NSDataDetector（英文等）

    /// 英文路径。注意：NSDataDetector 始终以真实当前时间为基准解析，忽略传入的 now（NSDataDetector 的限制），
    /// 因此英文相对日期的测试也只能用真实时间断言。
    private static func resolveWithDetector(
        _ text: String,
        now: Date,
        calendar: Calendar
    ) -> (date: Date, range: Range<String.Index>)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let date = match.date,
              let stringRange = Range(match.range, in: text)
        else { return nil }
        return (calendar.startOfDay(for: date), stringRange)
    }
}
