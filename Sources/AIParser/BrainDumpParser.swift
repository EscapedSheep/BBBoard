import Foundation
import FoundationModels
import RuleEngine

/// Brain Dump 解析：AI 可用时走 Foundation Models 结构化输出；
/// 任何错误（GuardrailViolation、模型未就绪等）或空结果都静默降级到规则解析器。
/// 模型只做语义理解；日期一律由 DateResolver 规则代码解析。
public enum BrainDumpParser {
    /// AI 提案的结构化输出 schema。
    /// status 用 String + Guide 约束取值（比 @Generable enum 更宽容：模型跑偏时由我们兜底）。
    @Generable
    struct Schema {
        @Guide(description: "拆分出的任务列表")
        var tasks: [Item]

        @Generable
        struct Item {
            @Guide(description: "简洁的任务标题，保留原文语言（中文输入用中文标题）")
            var title: String
            @Guide(description: "任务状态，必须是 today / doing / waiting / backlog 之一；在等待某人或某事（如“等XX回复”）时用 waiting；拿不准用 today")
            var status: String
            @Guide(description: "原文中出现的时间表述原始片段，如“明天”“下周五”“next Friday”，原样摘录，绝对不要自己计算或推断日期；没有时间表述则留空")
            var dueText: String?
            @Guide(description: "等待的人或事，如“Peter 的回复”；仅当 status 为 waiting 时填写，否则留空")
            var waitingOn: String?
        }
    }

    public static func parse(_ text: String, now: Date = Date()) async -> BrainDumpOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BrainDumpOutcome(proposals: [], usedFallback: false)
        }

        if AIAvailabilityProbe.current == .available {
            do {
                let proposals = try await aiParse(trimmed, now: now)
                if !proposals.isEmpty {
                    return BrainDumpOutcome(proposals: proposals, usedFallback: false)
                }
                NSLog("BoardApp: AI 解析返回空结果，降级到规则解析")
            } catch {
                // GuardrailViolation / 模型未就绪 / 上下文超限等：静默降级，用户无感
                NSLog("BoardApp: AI 解析失败（\(error)），降级到规则解析")
            }
        }

        return BrainDumpOutcome(
            proposals: FallbackParser.parse(trimmed, now: now),
            usedFallback: true
        )
    }

    private static func aiParse(_ text: String, now: Date) async throws -> [TaskProposal] {
        let instructions = """
        你是任务整理助手。把用户倾倒的杂乱想法拆分成独立、可执行的任务，不要编造原文没有的任务，\
        不要把上下文说明当作任务。今天是 \(todayDescription(now))。
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text, generating: Schema.self)
        return response.content.tasks.map { item in
            let dueText = item.dueText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDue = dueText.flatMap { $0.isEmpty ? nil : $0 }
                .flatMap { DateResolver.resolve($0, now: now) }
            return TaskProposal(
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                status: TaskStatus(rawValue: item.status) ?? .today,
                dueText: dueText?.isEmpty == true ? nil : dueText,
                dueDate: resolvedDue,
                waitingOn: item.waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// 给模型的时间锚点（它只用来理解相对时间的语义，不允许输出计算结果）。
    private static func todayDescription(_ now: Date) -> String {
        let calendar = Calendar.current
        let weekdays = ["", "日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[calendar.component(.weekday, from: now)]
        let day = now.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "zh_CN")))
        return "\(day)，周\(weekday)"
    }
}
