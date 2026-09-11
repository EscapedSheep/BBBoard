import Foundation
import RuleEngine
import UserNotifications

/// `BoardApp --selftest`：用样例 brain dump 跑规则解析器。
/// 仅开发期使用，不进 UI。
enum SelfTest {
    static func run() async {
        let samples = [
            "明天跟进 PRG 的 API key，等 Peter 回复。还有 invoice 接口的 bug 今天得修",
            "周五前把 customs XML 的测试跑完；下周三约 Hungary 团队确认需求，然后整理一下 backlog 里那些旧任务",
            "review the TEMU issue tomorrow and follow up with Sarah next Monday, also 别忘了把 invoice 那个接口文档更新一下",
        ]

        for sample in samples {
            print("\n--- input: \(sample)")
            let proposals = BrainDumpParser.parse(sample)
            if proposals.isEmpty {
                print("  (no proposals)")
            }
            for proposal in proposals {
                let due = proposal.dueDate.map { $0.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "zh_CN"))) } ?? "nil"
                print("  • [\(proposal.status.rawValue)] \(proposal.title) | dueText=\(proposal.dueText ?? "nil") → \(due) | waitingOn=\(proposal.waitingOn ?? "nil")")
            }
        }

        // M3 通知可行性探针：裸 SPM 可执行文件（无 bundle id）能否用 UNUserNotificationCenter。
        // 若此处进程直接崩溃（NSException），崩溃本身就是“不可行”的结论。
        print("\n== notification probe")
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert])
            print("requestAuthorization granted=\(granted)")
        } catch {
            print("requestAuthorization failed: \(error)")
        }
    }
}
