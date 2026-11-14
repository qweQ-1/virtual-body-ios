//
//  Speech.swift
//  虚拟身体（VirtualBody）
//
//  职责：原生 TTS。包装 AVSpeechSynthesizer，服务前端的两条指令：
//    {"cmd":"speak","text":"...","lang":"zh-CN"} / {"cmd":"stop_speak"}
//  中文语音优先（zh-CN，优先 enhanced 音色）；系统没有对应语音包时静默降级（不发声但不报错）。
//  音频会话用 .playback + .spokenAudio + duckOthers：不打断用户正在听的音乐，只在朗读时压低。
//

import Foundation
import AVFoundation
import Combine

final class SpeechEngine: NSObject, ObservableObject, @unchecked Sendable {

    /// 是否正在朗读（供 UI 显示，不需要也可忽略）
    @Published private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var sessionConfigured = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 朗读一段文字；未给 lang 时按 zh-CN 处理。空文本直接忽略。
    func speak(_ text: String, lang: String = "zh-CN") {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        configureAudioSessionIfNeeded()

        // 新的一句来了就打断旧的，避免排队念老台词
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: content)
        utterance.voice = voice(for: lang)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95   // 稍微慢一点，更像角色说话
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05

        synthesizer.speak(utterance)
        publishSpeaking(true)
    }

    /// 立即停止
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        publishSpeaking(false)
    }

    // MARK: - 内部

    private func configureAudioSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        // 任何一步失败都无所谓：TTS 仍会尽量发声，绝不因此崩溃
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    /// 选音色：优先目标语言的 enhanced 音色 → 系统默认该语言 → zh-CN → zh-TW
    private func voice(for lang: String) -> AVSpeechSynthesisVoice? {
        let wanted = lang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "zh-CN" : lang

        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let enhanced = voices.first(where: { $0.language == wanted && $0.quality == .enhanced }) {
            return enhanced
        }
        if let exact = AVSpeechSynthesisVoice(language: wanted) {
            return exact
        }
        if let zh = AVSpeechSynthesisVoice(language: "zh-CN") {
            return zh
        }
        return AVSpeechSynthesisVoice(language: "zh-TW")
    }

    private func publishSpeaking(_ value: Bool) {
        if Thread.isMainThread {
            isSpeaking = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = value
            }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechEngine: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        publishSpeaking(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        publishSpeaking(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        publishSpeaking(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        publishSpeaking(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        publishSpeaking(true)
    }
}
