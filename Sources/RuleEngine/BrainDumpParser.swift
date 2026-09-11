import Foundation

/// Brain Dump 规则解析器：按标点切分 + 连词剥离 + 日期规则 + “等X”等待规则。
public enum BrainDumpParser {
    private static let separatorRegex = try! NSRegularExpression(
        pattern: "[。，；、,;!！?？\n]+|(?i:\\s+and\\s+)|(?i:\\s+also\\s+)"
    )
    private static let conjunctionRegex = try! NSRegularExpression(pattern: "^(还有|然后|以及|并且?|(?i:and|also)\\b)\\s*")
    // “等”之后近距离出现等待类宾语才算等待语（“等 Peter 回复”是，“等级评定/等等再说”不是）
    private static let waitingObjectRegex = try! NSRegularExpression(
        pattern: "^.{0,12}?(?:的)?(?:回复|答复|反馈|确认|审批|审核|结果|消息|通知|回信|批准|签字|排期|报价|付款)"
    )

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> [TaskProposal] {
        var proposals: [TaskProposal] = []
        for fragment in fragments(of: text) {
            // 独立“等X”片段并入上一条任务（“跟进 PRG，等 Peter 回复”是一件事）
            if fragment.hasPrefix("等"), !proposals.isEmpty,
               let clause = waitingClause(in: fragment)
            {
                var previous = proposals[proposals.count - 1]
                previous.status = .waiting
                // 上一条已有等待对象时拼接而非覆盖（多方等待都保留）
                if let existing = previous.waitingOn, !existing.isEmpty {
                    previous.waitingOn = existing + "、" + clause.waitingOn
                } else {
                    previous.waitingOn = clause.waitingOn
                }
                proposals[proposals.count - 1] = previous
                continue
            }
            proposals.append(proposal(for: fragment, now: now, calendar: calendar))
        }
        return proposals
    }

    private static func proposal(for fragment: String, now: Date, calendar: Calendar) -> TaskProposal {
        var title = fragment
        var waitingOn: String?
        var status: TaskStatus = .today

        // 片段内的“等X”：标题取“等”之前的部分，等待对象取之后的部分
        if let clause = waitingClause(in: fragment) {
            status = .waiting
            waitingOn = clause.waitingOn
            if !clause.title.isEmpty { title = clause.title }
        }

        // 日期：规则解析，标题中剔除时间表述
        var dueText: String?
        var dueDate: Date?
        if let resolved = DateResolver.resolveWithRange(title, now: now, calendar: calendar) {
            dueText = String(title[resolved.range])
            dueDate = resolved.date
            title.removeSubrange(resolved.range)
            title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "，。、, ")))
            if title.isEmpty { title = fragment }
        }

        return TaskProposal(
            title: title,
            status: status,
            dueText: dueText,
            dueDate: dueDate,
            waitingOn: waitingOn
        )
    }

    /// 找到构成“等待某人/某事”语境的“等”：排除 等等/等级/等于/平等/高等/中等/低等/优等，
    /// 且“等”之后须跟等待类宾语（回复/审批/结果…，允许先出现等待对象如人名）。
    private static func waitingClause(in fragment: String) -> (title: String, waitingOn: String)? {
        var searchStart = fragment.startIndex
        while let range = fragment.range(of: "等", range: searchStart..<fragment.endIndex) {
            searchStart = range.upperBound
            let after = String(fragment[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if after.hasPrefix("等") || after.hasPrefix("级") || after.hasPrefix("于") { continue }
            if range.lowerBound > fragment.startIndex,
               ["平", "高", "中", "低", "优"].contains(fragment[fragment.index(before: range.lowerBound)])
            { continue }
            guard waitingObjectRegex.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil
            else { continue }
            let before = String(fragment[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (before, after)
        }
        return nil
    }

    /// 按标点切分，剥离片段开头的连词（还有/然后/以及/and…）。
    static func fragments(of text: String) -> [String] {
        let fullRange = NSRange(text.startIndex..., in: text)
        var fragments: [String] = []
        var lastEnd = text.startIndex
        for match in separatorRegex.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            fragments.append(String(text[lastEnd..<range.lowerBound]))
            lastEnd = range.upperBound
        }
        fragments.append(String(text[lastEnd...]))

        return fragments.compactMap { raw in
            var fragment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = conjunctionRegex.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)),
               let range = Range(match.range, in: fragment)
            {
                fragment.removeSubrange(range)
                fragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return fragment.isEmpty ? nil : fragment
        }
    }
}
