//
//  WingAddressTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct WingAddressTests {
    @Test func buildsStripNodes() {
        #expect(WingAddress.fader(.channel, 1) == "/ch/1/fdr")
        #expect(WingAddress.mute(.bus, 2) == "/bus/2/mute")
        #expect(WingAddress.name(.main, 1) == "/main/1/name")
        #expect(WingAddress.fader(.matrix, 3) == "/mtx/3/fdr")
        #expect(WingAddress.fader(.aux, 4) == "/aux/4/fdr")
        #expect(WingAddress.pan(.channel, 5) == "/ch/5/pan")
    }

    @Test func buildsInputPatchNodes() {
        #expect(WingAddress.channelSourceGroup(5) == "/ch/5/in/conn/grp")
        #expect(WingAddress.channelSourceIndex(5) == "/ch/5/in/conn/in")
    }

    @Test func buildsOutputPatchNodes() {
        #expect(WingAddress.outputSourceGroup(1) == "/io/out/1/srcgrp")
        #expect(WingAddress.outputSourceIndex(1) == "/io/out/1/srcin")
    }

    @Test func buildsSendNodes() {
        #expect(WingAddress.sendOn(.channel, 1, toBus: 3) == "/ch/1/send/3/on")
        #expect(WingAddress.sendLevel(.channel, 1, toBus: 3) == "/ch/1/send/3/lvl")
        #expect(WingAddress.mainOn(.channel, 2, toMain: 1) == "/ch/2/main/1/on")
        #expect(WingAddress.mainLevel(.channel, 2, toMain: 1) == "/ch/2/main/1/lvl")
    }

    @Test func exposesConsoleCommands() {
        #expect(WingAddress.subscribe == "/*S")
        #expect(WingAddress.info == "/?")
    }

    @Test func reportsStripCounts() {
        #expect(WingNodeKind.channel.count == 40)
        #expect(WingNodeKind.aux.count == 8)
        #expect(WingNodeKind.bus.count == 16)
        #expect(WingNodeKind.main.count == 4)
        #expect(WingNodeKind.matrix.count == 8)
    }
}
