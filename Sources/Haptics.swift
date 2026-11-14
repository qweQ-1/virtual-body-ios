//
//  Haptics.swift
//  虚拟身体（VirtualBody）
//
//  职责：原生触觉反馈。前端通过 {"cmd":"haptic","style":"light|medium|heavy|success|warning|error"}
//  触发；这里把 6 种语义映射到 CoreHaptics 细腻震动（优先）或 UIKit Taptic 生成器（回退）。
//
//  硬性要求：设备不支持、系统不支持、引擎启动失败、开关关闭 —— 一律静默降级，
//  绝不抛异常、绝不阻塞主线程、绝不崩。所有震动最终都在主线程发起。
//

import Foundation
import UIKit
import CoreHaptics

enum HapticStyle: String {
    case light
    case medium
    case heavy
    case soft
    case rigid
    case selection
    case success
    case warning
    case error
}

enum Haptics {

    /// 由设置页的「触觉反馈」开关控制（未设置过默认开）
    static var isEnabled: Bool { AppConfig.hapticsEnabled }

    /// 前端传来字符串 → 枚举；未知样式直接忽略
    static func trigger(named name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let style = HapticStyle(rawValue: key) else { return }
        trigger(style)
    }

    /// 触发一个语义触觉
    static func trigger(_ style: HapticStyle) {
        guard isEnabled else { return }
        runOnMain { perform(style) }
    }

    /// 预热（可选）：进入主界面时调一次，让 Taptic Engine 就绪、第一次震动不延迟
    static func prepare() {
        guard isEnabled else { return }
        runOnMain {
            _ = coreEngine()
            impactGenerator(for: .light, key: "light").prepare()
            impactGenerator(for: .medium, key: "medium").prepare()
            UINotificationFeedbackGenerator().prepare()
        }
    }

    // MARK: - 主线程调度

    private static func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - UIKit 回退实现

    private static var impactCache: [String: UIImpactFeedbackGenerator] = [:]

    private static func impactGenerator(for style: UIImpactFeedbackGenerator.FeedbackStyle,
                                        key: String) -> UIImpactFeedbackGenerator {
        if let cached = impactCache[key] { return cached }
        let generator = UIImpactFeedbackGenerator(style: style)
        impactCache[key] = generator
        return generator
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = impactGenerator(for: style, key: "\(style.rawValue)")
        generator.prepare()
        generator.impactOccurred()
    }

    private static func perform(_ style: HapticStyle) {
        switch style {
        case .light:
            impact(.light)
        case .medium:
            impact(.medium)
        case .heavy:
            impact(.heavy)
        case .soft:
            impact(.soft)
        case .rigid:
            impact(.rigid)
        case .selection:
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
        case .success:
            if playCoreHaptics(for: style) { return }
            notify(.success)
        case .warning:
            if playCoreHaptics(for: style) { return }
            notify(.warning)
        case .error:
            if playCoreHaptics(for: style) { return }
            notify(.error)
        }
    }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    // MARK: - CoreHaptics（细腻版 success / warning / error）

    private static var engine: CHHapticEngine?
    private static var engineStarted = false

    private static func coreEngine() -> CHHapticEngine? {
        if engineStarted, let engine = engine { return engine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let created = try CHHapticEngine()
            created.playsHapticsOnly = true
            created.stoppedHandler = { _ in
                engineStarted = false
            }
            created.resetHandler = {
                // 系统回收引擎后重新拉起；失败就算了，下次会再试
                do {
                    try engine?.start()
                    engineStarted = true
                } catch {
                    engineStarted = false
                }
            }
            try created.start()
            engine = created
            engineStarted = true
            return created
        } catch {
            engine = nil
            engineStarted = false
            return nil
        }
    }

    /// 返回 true 表示已经用 CoreHaptics 播过（调用方不要再叠 UIKit 震动，避免双重抖动）
    private static func playCoreHaptics(for style: HapticStyle) -> Bool {
        guard let engine = coreEngine() else { return false }
        let events: [CHHapticEvent]
        switch style {
        case .success:
            events = [
                transient(at: 0.00, intensity: 0.55, sharpness: 0.6),
                transient(at: 0.10, intensity: 0.85, sharpness: 0.35)
            ]
        case .warning:
            events = [
                transient(at: 0.00, intensity: 0.9, sharpness: 0.15),
                transient(at: 0.16, intensity: 0.6, sharpness: 0.1)
            ]
        default: // .error
            events = [
                transient(at: 0.00, intensity: 1.0, sharpness: 0.9),
                transient(at: 0.09, intensity: 0.8, sharpness: 0.8),
                transient(at: 0.18, intensity: 0.8, sharpness: 0.8)
            ]
        }
        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return false }
        do {
            try engine.start()
            engineStarted = true
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }

    private static func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ]
        return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: time)
    }
}
