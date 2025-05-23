//
//  File.swift
//  
//
//  Created by Mikhail Filimonov on 08.02.2024.
//

import Foundation
import TelegramCore
import Postbox
import AppKit
import SwiftSignalKit
import TelegramMedia
import TelegramVoip
import TGUIKit

internal final class Arguments {
    let toggleSecretKey:()->Void
    let makeAvatar:(NSView?, Peer?)->NSView?
    let makeParticipants:(NSView?, [EnginePeer])->NSView
    let openSettings:()->Void
    let addMembers:()->Void
    init(toggleSecretKey:@escaping()->Void, makeAvatar:@escaping(NSView?, Peer?)->NSView?, makeParticipants:@escaping(NSView?, [EnginePeer])->NSView, openSettings:@escaping()->Void, addMembers:@escaping()->Void) {
        self.toggleSecretKey = toggleSecretKey
        self.makeAvatar = makeAvatar
        self.openSettings = openSettings
        self.addMembers = addMembers
        self.makeParticipants = makeParticipants
    }
}


public final class PeerCallArguments {
    let peerId: PeerId
    let engine: TelegramEngine
    let makeAvatar:(NSView?, Peer?)->NSView
    let makeParticipants:(NSView?, [EnginePeer])->NSView
    let toggleMute:()->Void
    let toggleCamera:(ExternalPeerCallState)->Void
    let toggleScreencast:(ExternalPeerCallState)->Void
    let endcall:(ExternalPeerCallState)->Void
    let recall:()->Void
    let acceptcall:()->Void
    let video:(Bool)->Signal<OngoingGroupCallContext.VideoFrameData, NoError>?
    let audioLevel:()->Signal<Float, NoError>
    let openSettings:(Window)->Void
    let upgradeToConference:(Window)->Void
    public init(engine: TelegramEngine, peerId: PeerId, makeAvatar: @escaping (NSView?, Peer?) -> NSView, makeParticipants:@escaping(NSView?, [EnginePeer])->NSView, toggleMute:@escaping()->Void, toggleCamera:@escaping(ExternalPeerCallState)->Void, toggleScreencast:@escaping(ExternalPeerCallState)->Void, endcall:@escaping(ExternalPeerCallState)->Void, recall:@escaping()->Void, acceptcall:@escaping()->Void, video:@escaping(Bool)->Signal<OngoingGroupCallContext.VideoFrameData, NoError>?, audioLevel:@escaping()->Signal<Float, NoError>, openSettings:@escaping(Window)->Void, upgradeToConference:@escaping(Window)->Void) {
        self.engine = engine
        self.peerId = peerId
        self.makeParticipants = makeParticipants
        self.makeAvatar = makeAvatar
        self.toggleMute = toggleMute
        self.toggleCamera = toggleCamera
        self.toggleScreencast = toggleScreencast
        self.endcall = endcall
        self.recall = recall
        self.acceptcall = acceptcall
        self.video = video
        self.audioLevel = audioLevel
        self.openSettings = openSettings
        self.upgradeToConference = upgradeToConference
    }
}
