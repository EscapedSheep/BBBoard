import Foundation
import Observation
import RuleEngine

/// 用户可调设置（M5）：UserDefaults 持久化，@Observable 供 SwiftUI 直接绑定。
/// 规则/Focus/Cleanup 的阈值从这里流向 RuleEngine 的纯函数配置。
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Daily Focus 条数（1...5）
    var focusMaxItems: Int {
        didSet { defaults.set(focusMaxItems, forKey: Keys.focusMaxItems) }
    }
    /// 距截止多少天内视为「临近」
    var dueApproachingDays: Int {
        didSet { defaults.set(dueApproachingDays, forKey: Keys.dueApproachingDays) }
    }
    /// waiting 多少天视为「等太久」（建议 + 停滞共用起点）
    var waitingTooLongDays: Int {
        didSet { defaults.set(waitingTooLongDays, forKey: Keys.waitingTooLongDays) }
    }
    /// doing 多少天没更新视为「做太久」
    var doingTooLongDays: Int {
        didSet { defaults.set(doingTooLongDays, forKey: Keys.doingTooLongDays) }
    }
    /// backlog 多少天未动视为停滞（Smart Cleanup）
    var backlogStaleDays: Int {
        didSet { defaults.set(backlogStaleDays, forKey: Keys.backlogStaleDays) }
    }
    /// 全局快捷键 ⌥Space 开关
    var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Keys.hotkeyEnabled) }
    }
    /// 桌面看板收起（紧凑）时仍常驻显示 FOCUS 区
    var focusPinnedInCompact: Bool {
        didSet { defaults.set(focusPinnedInCompact, forKey: Keys.focusPinnedInCompact) }
    }

    /// 全部阈值项的联合签名：任一变化都应触发派生数据重算
    var thresholdsSignature: Int {
        var hasher = Hasher()
        for value in [focusMaxItems, dueApproachingDays, waitingTooLongDays, doingTooLongDays, backlogStaleDays] {
            hasher.combine(value)
        }
        return hasher.finalize()
    }

    var ruleThresholds: RuleThresholds {
        RuleThresholds(
            dueApproachingDays: dueApproachingDays,
            waitingTooLongDays: waitingTooLongDays,
            doingTooLongDays: doingTooLongDays
        )
    }

    var focusConfig: FocusConfig {
        var config = FocusConfig.default
        config.maxItems = focusMaxItems
        return config
    }

    var cleanupConfig: CleanupConfig {
        CleanupConfig(
            backlogStaleDays: backlogStaleDays,
            doingStaleDays: doingTooLongDays,
            waitingStaleDays: waitingTooLongDays
        )
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) as? Int ?? fallback
        }
        self.focusMaxItems = int(Keys.focusMaxItems, FocusConfig.default.maxItems)
        self.dueApproachingDays = int(Keys.dueApproachingDays, RuleThresholds.default.dueApproachingDays)
        self.waitingTooLongDays = int(Keys.waitingTooLongDays, RuleThresholds.default.waitingTooLongDays)
        self.doingTooLongDays = int(Keys.doingTooLongDays, RuleThresholds.default.doingTooLongDays)
        self.backlogStaleDays = int(Keys.backlogStaleDays, CleanupConfig.default.backlogStaleDays)
        self.hotkeyEnabled = defaults.object(forKey: Keys.hotkeyEnabled) as? Bool ?? true
        self.focusPinnedInCompact = defaults.object(forKey: Keys.focusPinnedInCompact) as? Bool ?? true
    }

    private enum Keys {
        static let focusMaxItems = "BBBoard.focusMaxItems"
        static let dueApproachingDays = "BBBoard.dueApproachingDays"
        static let waitingTooLongDays = "BBBoard.waitingTooLongDays"
        static let doingTooLongDays = "BBBoard.doingTooLongDays"
        static let backlogStaleDays = "BBBoard.backlogStaleDays"
        static let hotkeyEnabled = "BBBoard.hotkeyEnabled"
        static let focusPinnedInCompact = "BBBoard.focusPinnedInCompact"
    }
}
