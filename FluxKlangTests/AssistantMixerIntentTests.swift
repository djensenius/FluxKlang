import Foundation
import Testing

@testable import FluxKlang

struct AssistantMixerIntentTests {
    @Test func explicitGrammar() {
        let examples: [(String, AssistantMixerCommand)] = [
            ("set main to -10 dB", .init(target: .main(1), operation: .setDB(-10))),
            ("  SET  channel 7 TO -12.5 DB ", .init(target: .channel(7), operation: .setDB(-12.5))),
            ("set main 4 to +10 dB", .init(target: .main(4), operation: .setDB(10))),
            ("set channel 40 to -90 dB", .init(target: .channel(40), operation: .setDB(-90))),
            ("lower Lead Synth by 3.5 dB", .init(target: .liveName("lead synth"), operation: .adjustDB(-3.5))),
            ("raise channel 2 by .5 dB", .init(target: .channel(2), operation: .adjustDB(0.5))),
            ("turn main down by 3 dB", .init(target: .main(1), operation: .adjustDB(-3))),
            ("turn down channel7 by3dB", .init(target: .channel(7), operation: .adjustDB(-3))),
            ("turn channel 7 up by 2.5dB", .init(target: .channel(7), operation: .adjustDB(2.5))),
            ("turn up Lead Synth by3 dB", .init(target: .liveName("lead synth"), operation: .adjustDB(3))),
            ("mute main", .init(target: .main(1), operation: .mute(true))),
            ("unmute channel 9", .init(target: .channel(9), operation: .mute(false)))
        ]
        for (text, expected) in examples { #expect(AssistantMixerIntent.parse(text) == .command(expected)) }
    }

    @Test(arguments: AssistantMixerRejectionCases.texts)
    func rejectsAmbiguousOrNonDirectText(_ text: String) {
        guard case .clarification = AssistantMixerIntent.parse(text) else {
            Issue.record("Unsafe/ambiguous mixer text must block downstream handling: \(text)")
            return
        }
    }

    @Test func routingIsNotAMixerCommand() {
        for text in ["route Synth through Echo to speakers", "help me set up my studio",
                     "list equipment named Volume", "route Lower Synth to speakers"] {
            #expect(AssistantMixerIntent.parse(text) == .notMixerIntent)
        }
    }

    @Test func resolverRequiresExactUniqueLiveNameAndNeverSelectsStereoLeft() {
        let mono = FaderLayout(strips: [.init(node: .channel(7), customLabel: "Saved Name")])
        #expect(
            AssistantMixerTargetResolver.resolve(.liveName(" lead "), names: [7: "Lead"], layout: mono)
                == .node(.channel(7)))
        for (target, names) in [
            ("Lead", [7: "Lead", 8: "Lead"]), ("Lea", [7: "Lead"]),
            ("Saved Name", [7: "Lead"]), ("Synth", [7: "Synth L", 8: "Synth R"])
        ] {
            if case .node = AssistantMixerTargetResolver.resolve(.liveName(target), names: names, layout: mono) {
                Issue.record("Unsafe name resolution: \(target)")
            }
        }
        let stereo = FaderLayout(strips: [.init(node: .channel(7), rightNode: .channel(8), customLabel: "Synth")])
        if case .node = AssistantMixerTargetResolver.resolve(.liveName("Lead"), names: [7: "Lead"], layout: stereo) {
            Issue.record("Named stereo resolved to its left side")
        }
        #expect(AssistantMixerTargetResolver.resolve(.channel(7), names: [:], layout: stereo) == .node(.channel(7)))
    }
}

enum AssistantMixerRejectionCases {
    static let texts = [
        "turn down volume", "turn main down", "turn down channel7", "turn down by3dB",
        "turn main down by nan dB", "turn main up by -3dB", "lower main", "raise channel 7", "mute", "unmute it",
        "set channel 0 to -10 dB", "set channel 41 to -10 dB", "mute main 5",
        "set main to nan dB", "set main to inf dB", "set main to -91 dB", "set main to 11 dB",
        "set main to 50%", "set main to -10", "lower main by -3 dB", "raise main by 0 dB",
        "don't mute main", "do not mute main", "never mute main", "not mute main",
        "how do I mute main?", "explain mute main", "if mute main", "what is set main to -10 dB",
        "\"mute main\"", "‘mute main’", "mute main; unmute channel 1", "mute main and channel 7",
        "mute main then route synth to speakers", "route synth to speakers and lower main by 3 dB",
        "route Synth to speakers. mute main", "route Synth to speakers: mute main",
        "route Synth to speakers & mute main", "route Synth to speakers! mute main",
        "route Synth to speakers? mute main", "route Synth to speakers — mute main",
        "set main to -10 dB\nmute channel 1", "mute /ch/1", "mute volume", "set main to 1e5 dB"
    ]
}
