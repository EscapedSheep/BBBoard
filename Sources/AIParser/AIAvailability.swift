import Foundation
import FoundationModels

/// Apple Intelligence 可用性（降级路径是一等功能，这里只做状态探测与暴露）。
public enum AIAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady

    /// 面向 UI 的简短提示；available 时不需要提示。
    public var hint: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceNotEnabled: "本地 AI 未开启，使用规则解析"
        case .deviceNotEligible: "设备不支持本地 AI，使用规则解析"
        case .modelNotReady: "本地 AI 模型未就绪，使用规则解析"
        }
    }
}

public enum AIAvailabilityProbe {
    public static var current: AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
            case .deviceNotEligible: .deviceNotEligible
            case .modelNotReady: .modelNotReady
            @unknown default: .modelNotReady
            }
        }
    }
}
