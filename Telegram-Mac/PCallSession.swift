//
//  CallSession.swift
//  Telegram
//
//  Created by keepcoder on 03/05/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import SwiftSignalKit
import TelegramCore
import InAppSettings
import Postbox
import TGUIKit
import CoreGraphics

import TelegramVoip
import TgVoipWebrtc

public enum PresentationCallConferenceState {
    case preparing
    case ready
}

enum CallTone {
    case undefined
    case ringback
    case busy
    case connecting
    case failed
    case ended
    case ringing
}

enum ScreenCaptureLaunchError {
    case permission
}


extension CallState.State {
    func statusText(_ accountPeer: Peer?, _ videoState: CallState.VideoState) -> CallControllerStatusValue {
        let statusValue: CallControllerStatusValue
        switch self {
        case .waiting, .connecting:
            statusValue = .text(strings().callStatusConnecting, nil)
        case let .requesting(ringing):
            if ringing {
                statusValue = .text(strings().callStatusRinging, nil)
            } else {
                statusValue = .text(strings().callStatusRequesting, nil)
            }
        case .terminating:
            statusValue = .text(strings().callStatusEnded, nil)
        case let .terminated(_, reason, _):
            if let reason = reason {
                switch reason {
                case let .ended(type):
                    switch type {
                    case .busy:
                        statusValue = .text(strings().callStatusBusy, nil)
                    case .hungUp, .missed:
                        statusValue = .text(strings().callStatusEnded, nil)
                    case .switchedToConference:
                        statusValue = .text(strings().callStatusEnded, nil)
                    }
                case .error:
                    statusValue = .text(strings().callStatusFailed, nil)
                }
            } else {
                statusValue = .text(strings().callStatusEnded, nil)
            }
        case .ringing:
            if let accountPeer = accountPeer {
                statusValue = .text(strings().callStatusCallingAccount(accountPeer.addressName ?? accountPeer.compactDisplayTitle), nil)
            } else {
                statusValue = .text(strings().callStatusCalling, nil)
            }
        case .active(let timestamp, let reception, _), .reconnecting(let timestamp, let reception, _):
            if case .reconnecting = self {
                statusValue = .text(strings().callStatusConnecting, reception)
            } else {
                statusValue = .timer(timestamp, reception)
            }
        }
        return statusValue
    }
}






public struct CallAuxiliaryServer {
    public enum Connection {
        case stun
        case turn(username: String, password: String)
    }
    
    public let host: String
    public let port: Int
    public let connection: Connection
    
    public init(
        host: String,
        port: Int,
        connection: Connection
        ) {
        self.host = host
        self.port = port
        self.connection = connection
    }
}
 struct CallState: Equatable {
    enum State: Equatable {
        case waiting
        case ringing
        case requesting(Bool)
        case connecting(Data?)
        case active(Double, Int32?, Data)
        case reconnecting(Double, Int32?, Data)
        case terminating(CallSessionTerminationReason?)
        case terminated(CallId?, CallSessionTerminationReason?, Bool)
    }
    
    
    enum VideoState: Equatable {
        case notAvailable
        case inactive(Bool)
        case active(Bool)
        case paused(Bool)

    }
    
    
    public enum RemoteAudioState: Equatable {
        case active
        case muted
    }
    
    public enum RemoteBatteryLevel: Equatable {
        case normal
        case low
    }

    
    enum RemoteVideoState: Equatable {
        case inactive
        case active
        case paused
    }
    
    
    let state: State
    let videoState: VideoState
    let remoteVideoState: RemoteVideoState
    let isMuted: Bool
    let isOutgoingVideoPaused: Bool
    let remoteAspectRatio: Float
    let remoteAudioState: RemoteAudioState
    let remoteBatteryLevel: RemoteBatteryLevel
    let isScreenCapture: Bool
    let participants: [EnginePeer]
    let conferenceReference: MessageId?
    let supportsConferenceCalls: Bool


     init(state: State, videoState: VideoState, remoteVideoState: RemoteVideoState, isMuted: Bool, isOutgoingVideoPaused: Bool, remoteAspectRatio: Float, remoteAudioState: RemoteAudioState, remoteBatteryLevel: RemoteBatteryLevel, isScreenCapture: Bool, participants: [EnginePeer], conferenceReference: MessageId?, supportsConferenceCalls: Bool) {
        self.state = state
        self.videoState = videoState
        self.remoteVideoState = remoteVideoState
        self.isMuted = isMuted
        self.isOutgoingVideoPaused = isOutgoingVideoPaused
        self.remoteAspectRatio = remoteAspectRatio
        self.remoteAudioState = remoteAudioState
        self.remoteBatteryLevel = remoteBatteryLevel
        self.isScreenCapture = isScreenCapture
        self.participants = participants
        self.conferenceReference = conferenceReference
        self.supportsConferenceCalls = supportsConferenceCalls
    }
}




let callQueue = Queue(name: "VoIPQueue")



private func getAuxiliaryServers(appConfiguration: AppConfiguration) -> [CallAuxiliaryServer] {
    guard let data = appConfiguration.data else {
        return []
    }
    guard let servers = data["rtc_servers"] as? [[String: Any]] else {
        return []
    }
    var result: [CallAuxiliaryServer] = []
    for server in servers {
        guard let host = server["host"] as? String else {
            continue
        }
        guard let portString = server["port"] as? String else {
            continue
        }
        guard let username = server["username"] as? String else {
            continue
        }
        guard let password = server["password"] as? String else {
            continue
        }
        guard let port = Int(portString) else {
            continue
        }
        result.append(CallAuxiliaryServer(
            host: host,
            port: port,
            connection: .stun
        ))
        result.append(CallAuxiliaryServer(
            host: host,
            port: port,
            connection: .turn(
                username: username,
                password: password
            )
        ))
    }
    return result
}

func getPrivateCallSessionData(_ account: Account, accountManager: AccountManager<TelegramAccountManagerTypes>, peerId: PeerId) -> Signal<PCallSession.InitialData, NoError> {
    return combineLatest(
        account.postbox.preferencesView(keys: [PreferencesKeys.voipConfiguration, ApplicationSpecificPreferencesKeys.voipDerivedState, PreferencesKeys.appConfiguration]),
        account.postbox.transaction { transaction -> Peer? in
            return transaction.getPeer(peerId)
        },
        voiceCallSettings(accountManager),
        proxySettings(accountManager: accountManager),
        account.networkType
    ) |> take(1) |> map { preferences, peer, voiceSettings, proxy, networkType in
        
        let configuration = preferences.values[PreferencesKeys.voipConfiguration]?.get(VoipConfiguration.self) ?? VoipConfiguration.defaultValue
        let appConfiguration = preferences.values[PreferencesKeys.appConfiguration]?.get(AppConfiguration.self) ?? AppConfiguration.defaultValue
        let derivedState = preferences.values[ApplicationSpecificPreferencesKeys.voipDerivedState]?.get(VoipDerivedState.self) ?? VoipDerivedState.default
        
        return PCallSession.InitialData(configuration: configuration, appConfiguration: appConfiguration, derivedState: derivedState, peer: peer, voiceSettings: voiceSettings, proxyServerSettings: proxy.effectiveActiveServer, networkType: networkType)
    }
}

class PCallSession {
    
    struct InitialData {
        let configuration: VoipConfiguration
        let appConfiguration: AppConfiguration
        let derivedState: VoipDerivedState
        let peer: Peer?
        let voiceSettings: VoiceCallSettings
        let proxyServerSettings: ProxyServerSettings?
        let networkType: NetworkType
    }
    
    let peerId:PeerId
    let account: Account
    let internalId:CallSessionInternalId
    
    private(set) var peer: Peer?
    private let peerDisposable = MetaDisposable()
    private var sessionState: CallSession?
    
    private var ongoingContext: OngoingCallContext?
    private var callContextState: OngoingCallContextState?
    private var ongoingContextStateDisposable: Disposable?
    private var reception: Int32?
    private var requestedVideoAspect: Float?
    private var receptionDisposable: Disposable?
    
    
    private let serializedData: String?
    private let dataSaving: VoiceCallDataSaving
    private let derivedState: VoipDerivedState
    private let proxyServer: ProxyServerSettings?
    private let auxiliaryServers: [OngoingCallContext.AuxiliaryServer]
    private let currentNetworkType: NetworkType
    private let updatedNetworkType: Signal<NetworkType, NoError>
    
    
    
    private let stateDisposable = MetaDisposable()
    private let timeoutDisposable = MetaDisposable()
    private let devicesDisposable = MetaDisposable()
    
    private let sessionStateDisposable = MetaDisposable()
    
    private let statePromise:ValuePromise<CallState> = ValuePromise()
    private var presentationState: CallState? = nil
    var state:Signal<CallState, NoError> {
        return statePromise.get()
    }
    private let audioLevelPromise: Promise<Float> = Promise(0)
    var audioLevel:Signal<Float, NoError> {
        return audioLevelPromise.get()
    }
    
    private let canBeRemovedPromise = Promise<Bool>(false)
    private var didSetCanBeRemoved = false {
        didSet {
            if didSetCanBeRemoved {
                accountContext.sharedContext.dropCrossCall()
            }
        }
    }
    public var canBeRemoved: Signal<Bool, NoError> {
        return self.canBeRemovedPromise.get()
    }
    
    private let hungUpPromise = ValuePromise<Bool>()
    
    private var activeTimestamp: Double?
    
    
    private var player:CallAudioPlayer? = nil
    private var playingRingtone:Bool = false
    
    private var startTime:Double = 0
    private var callAcceptedTime:Double = 0
    
    private var completed: Bool = false
    private let requestMicroAccessDisposable = MetaDisposable()
    
    
    private let callSessionManager: CallSessionManager
    
    private var videoCapturer: OngoingCallVideoCapturer?
    
    let isOutgoing: Bool
    private(set) var isVideo: Bool
    private(set) var isVideoPossible: Bool
    private let isVideoAvailable: Bool
    private var videoIsForceDisabled: Bool
    private(set) var isScreenCapture: Bool
    private var screenCaptureSource: VideoSourceMac?
    private let enableStunMarking: Bool
    private let enableTCP: Bool
    public let preferredVideoCodec: String?
    
    private let incomingConferenceSource: EngineMessage.Id?
    private let conferenceStableId: Int64?
    
    private var supportsConferenceCalls: Bool = true
    
    weak var window: Window?


    
    var isIncomingConference: Bool {
        return incomingConferenceSource != nil
    }

    private var incomingParticipants: [EnginePeer]
    
    private var callWasActive = false
    private var videoWasActive = false
    
    private var previousVideoState: CallState.VideoState?
    private var previousRemoteVideoState: CallState.RemoteVideoState?
    private var previousRemoteAudioState: CallState.RemoteAudioState?
    private var previousRemoteBatteryLevel: CallState.RemoteBatteryLevel?
    
    
    private var delayMuteState: Bool? = nil
    
    private var droppedCall = false
    private var dropCallKitCallTimer: SwiftSignalKit.Timer?
    
    private var remoteAspectRatio: Float = 0
    private var remoteBatteryLevel: CallState.RemoteBatteryLevel = .normal
    private var remoteAudioState: CallState.RemoteAudioState = .active
    
    private var settingsDisposable: Disposable?
    private var devicesContext: DevicesContext
    let accountContext: AccountContext
    
    
    private weak var conferenceCallImpl: PresentationGroupCallImpl?
    public var conferenceCall: PresentationGroupCall? {
        return self.conferenceCallImpl
    }
    private var conferenceCallDisposable: Disposable?
    private var upgradedToConferenceCompletions = Bag<(PresentationGroupCall) -> Void>()

    
    private var isAcceptingIncomingConference: Bool = false
    private var waitForConferenceCallReadyDisposable: Disposable?
    private let conferenceStatePromise = ValuePromise<PresentationCallConferenceState?>(nil)
    public private(set) var conferenceStateValue: PresentationCallConferenceState? {
        didSet {
            if self.conferenceStateValue != oldValue {
                self.conferenceStatePromise.set(self.conferenceStateValue)
            }
        }
    }
    public var conferenceState: Signal<PresentationCallConferenceState?, NoError> {
        return self.conferenceStatePromise.get()
    }
    
    public private(set) var pendingInviteToConferencePeerIds: [EnginePeer.Id] = []
    
    private var devices: IODevices = .init(camera: [], audioInput: [], audioOutput: [], loading: true)
    private let devicesListDisposable = MetaDisposable()
    
    init(accountContext: AccountContext, account: Account, isOutgoing: Bool, incomingConferenceSource: EngineMessage.Id?, incomingParticipants: [EnginePeer], peerId:PeerId, id: CallSessionInternalId, initialState:CallSession?, startWithVideo: Bool, isVideoPossible: Bool, data: PCallSession.InitialData) {
        
        self.account = account
        self.accountContext = accountContext
        self.peerId = peerId
        self.internalId = id
        self.incomingParticipants = incomingParticipants
        self.callSessionManager = account.callSessionManager
        self.updatedNetworkType = account.networkType
        self.isOutgoing = isOutgoing
        self.incomingConferenceSource = incomingConferenceSource
        
        if let _ = incomingConferenceSource {
            self.conferenceStableId = Int64.random(in: Int64.min ..< Int64.max)
        } else {
            self.conferenceStableId = nil
        }

        
        self.isScreenCapture = false
        self.isVideo = initialState?.type == .video
        self.isVideo = self.isVideo || startWithVideo
        
        let devices = AVCaptureDevice.devices(for: .video).filter({ $0.isConnected && !$0.isSuspended })
        
        self.isVideoPossible = isVideoPossible && !devices.isEmpty
        
        self.videoIsForceDisabled = !isVideoPossible
        
        let isVideoAvailable: Bool
        if #available(OSX 10.14, *) {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .notDetermined:
                isVideoAvailable = true
            case .authorized:
                isVideoAvailable = true
            case .denied:
                isVideoAvailable = false
            case .restricted:
                isVideoAvailable = false
            @unknown default:
                isVideoAvailable = false
            }
        } else {
            isVideoAvailable = true
        }
        
        self.isVideoAvailable = isVideoAvailable
        
        
        let context = self.accountContext
        
        self.serializedData = data.configuration.serializedData
        self.dataSaving = .never
        self.derivedState = data.derivedState
        self.proxyServer = data.proxyServerSettings
        self.peer = data.peer
        self.currentNetworkType = data.networkType
        self.devicesContext = accountContext.sharedContext.devicesContext
        self.enableStunMarking = false
        self.enableTCP = false
        self.preferredVideoCodec = nil
        
        if self.isVideo {
            self.videoCapturer = OngoingCallVideoCapturer(devicesContext.currentCameraId ?? "")
            self.statePromise.set(CallState(state: isOutgoing ? .waiting : .ringing, videoState: self.isVideoPossible ? .active(self.isVideoAvailable) : .notAvailable, remoteVideoState: .inactive, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls))
        } else {
            self.statePromise.set(CallState(state: isOutgoing ? .waiting : .ringing, videoState: .notAvailable, remoteVideoState: .inactive, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls))
        }
        
        
        self.auxiliaryServers = getAuxiliaryServers(appConfiguration: data.appConfiguration).map { server -> OngoingCallContext.AuxiliaryServer in
            let mappedConnection: OngoingCallContext.AuxiliaryServer.Connection
            switch server.connection {
            case .stun:
                mappedConnection = .stun
            case let .turn(username, password):
                mappedConnection = .turn(username: username, password: password)
            }
            return OngoingCallContext.AuxiliaryServer(
                host: server.host,
                port: server.port,
                connection: mappedConnection
            )
        }
        
        devicesDisposable.set(self.devicesContext.updater().start(next: { [weak self] values in
            guard let `self` = self else {
                return
            }
            if isVideoAvailable, self.isVideo, !self.isOutgoingVideoPaused, let id = values.camera {
                self.videoCapturer?.switchVideoInput(id)
            }
            if let id = values.input {
                self.ongoingContext?.switchAudioInput(id)
            }
            if let id = values.output {
                self.ongoingContext?.switchAudioOutput(id)
            }
        }))
        
        if let incomingConferenceSource = incomingConferenceSource {
            self.sessionStateDisposable.set((context.engine.data.subscribe(
                TelegramEngine.EngineData.Item.Messages.Message(id: incomingConferenceSource)
            )
            |> deliverOnMainQueue).startStrict(next: { [weak self] message in
                guard let self else {
                    return
                }

                let state: CallSessionState
                if let message = message {
                    var foundAction: TelegramMediaAction?
                    for media in message.media {
                        if let action = media as? TelegramMediaAction {
                            foundAction = action
                            break
                        }
                    }

                    if let action = foundAction, case let .conferenceCall(conferenceCall) = action.action {
                        if conferenceCall.flags.contains(.isMissed) || conferenceCall.duration != nil {
                            state = .terminated(id: nil, reason: .ended(.hungUp), options: CallTerminationOptions())
                        } else {
                            state = .ringing
                        }
                    } else {
                        state = .terminated(id: nil, reason: .ended(.hungUp), options: CallTerminationOptions())
                    }
                } else {
                    state = .terminated(id: nil, reason: .ended(.hungUp), options: CallTerminationOptions())
                }
                
                self.updateSessionState(
                    sessionState: CallSession(
                        id: self.internalId,
                        stableId: self.conferenceStableId,
                        isOutgoing: false,
                        type: self.isVideo ? .video : .audio,
                        state: state,
                        isVideoPossible: true
                    ),
                    callContextState: nil,
                    reception: nil
                )
            }))
        } else {
            var callSessionState: Signal<CallSession, NoError> = .complete()
            if let initialState = initialState {
                callSessionState = .single(initialState)
            }
            callSessionState = callSessionState
            |> then(callSessionManager.callState(internalId: id))
            
            let signal = callSessionState |> deliverOn(callQueue)
            
            self.sessionStateDisposable.set(signal.start(next: { [weak self] sessionState in
                if let strongSelf = self {
                    strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: strongSelf.reception)
                }
            }))
        }
        
        DispatchQueue.main.async {
            accountContext.sharedContext.showCall(with: self)
        }
        
        devicesListDisposable.set((devicesContext.signal |> deliverOnMainQueue).start(next: { [weak self] devices in
            self?.devices = devices
        }))
    }
    
    
    private func startTimeout(_ duration:TimeInterval, discardReason: CallSessionTerminationReason) {
        timeoutDisposable.set((Signal<Void, NoError>.complete() |> delay(duration, queue: Queue.mainQueue())).start(completed: { [weak self] in
            self?.discardCurrentCallWithReason(discardReason)
        }))
    }
    
    
    private func invalidateTimeout() {
        timeoutDisposable.set(nil)
    }
    
    private var callReceiveTimeout:TimeInterval {
        return 30
    }
    private var callRingTimeout:TimeInterval {
        return 30
    }
    private var callConnectTimeout:TimeInterval {
        return 30
    }
    private var callPacketTimeout:TimeInterval {
        return 30
    }
    
    var callConnectionDuration: TimeInterval {
        if callAcceptedTime > Double.ulpOfOne && startTime > Double.ulpOfOne {
            return startTime - callAcceptedTime
        }
        return 0.0
    }
    
    var duration: TimeInterval {
        if startTime > Double.ulpOfOne {
            return CFAbsoluteTimeGetCurrent() - startTime;
        }
        return 0.0;
    }
    
    func stopTransmission(_ id: CallId?) {
        ongoingContext?.stop(callId: id, sendDebugLogs: false, debugLogValue: Promise())
    }
    
    func drop(_ reason:DropCallReason) {
        account.callSessionManager.drop(internalId: internalId, reason: reason, debugLog: .single(nil))
    }
    private func acceptAfterAccess() {
        callAcceptedTime = CFAbsoluteTimeGetCurrent()
        
        if self.incomingConferenceSource != nil {
            self.conferenceStateValue = .preparing
            self.isAcceptingIncomingConference = true
            self.sessionStateDisposable.dispose()
            
            self.updateSessionState(sessionState: CallSession(
                id: self.internalId,
                stableId: self.conferenceStableId,
                isOutgoing: false,
                type: self.isVideo ? .video : .audio,
                state: .ringing,
                isVideoPossible: true
            ),
            callContextState: nil, reception: nil)
            
            let context = self.accountContext
            guard let window = self.window else {
                return
            }
            
            
        } else {
            account.callSessionManager.accept(internalId: internalId)
        }
    }
    
    func acceptCallSession() {
        let accountContext = self.accountContext
        requestMicroAccessDisposable.set((requestMicrophonePermission() |> deliverOnMainQueue).start(next: { [weak self] access in
            if access {
                self?.acceptAfterAccess()
            } else {
                verifyAlert_button(for: accountContext.window, information: strings().requestAccesErrorHaveNotAccessCall, ok: strings().modalOK, cancel: "", option: strings().requestAccesErrorConirmSettings, successHandler: { [weak self] result in
                    switch result {
                    case .thrid:
                        openSystemSettings(.microphone)
                    default:
                        break
                    }
                    self?.drop(.hangUp)
                })
            }
        }))
        
    }
    
    
    
    private var isOutgoingVideoPaused: Bool = false
    private var isMuted: Bool = false
    
    func mute() {
        self.isMuted = true
        ongoingContext?.setIsMuted(self.isMuted)
        if ongoingContext == nil {
            delayMuteState = true
        }
    }
    
    func unmute() {
        self.isMuted = false
        ongoingContext?.setIsMuted(self.isMuted)
        if ongoingContext == nil {
            delayMuteState = nil
        }
    }
    
    func toggleMute() {
        self.isMuted = !self.isMuted
        ongoingContext?.setIsMuted(self.isMuted)
        if let state = self.sessionState {
            self.updateSessionState(sessionState: state, callContextState: self.callContextState, reception: self.reception)
        }
        if ongoingContext == nil {
            delayMuteState = self.isMuted ? true : nil
        }
    }
    
    private func updateSessionState(sessionState: CallSession, callContextState: OngoingCallContextState?, reception: Int32?) {
        if case .video = sessionState.type {
            self.isVideo = true
        }
        let previous = self.sessionState
        self.sessionState = sessionState
        self.callContextState = callContextState
        self.reception = reception
        
        
        var presentationState: CallState?
        
        var wasActive = false
        var wasTerminated = false
        if let previous = previous {
            switch previous.state {
            case .active:
                wasActive = true
            case .terminated:
                wasTerminated = true
            default:
                break
            }
        }
        
        
        self.remoteAspectRatio = callContextState?.remoteAspectRatio ?? 0
        
        let mappedVideoState: CallState.VideoState
        let mappedRemoteVideoState: CallState.RemoteVideoState
        let mappedRemoteAudioState: CallState.RemoteAudioState
        let mappedRemoteBatteryLevel: CallState.RemoteBatteryLevel
        if let callContextState = callContextState {
            switch callContextState.videoState {
            case .notAvailable:
                mappedVideoState = .notAvailable
            case .active:
                if videoIsForceDisabled {
                    mappedVideoState = .inactive(self.isVideoAvailable)
                } else {
                    mappedVideoState = .active(self.isVideoAvailable)
                }
            case .inactive:
                mappedVideoState = .inactive(self.isVideoAvailable)
            case .paused:
                mappedVideoState = .paused(self.isVideoAvailable)
            }
            switch callContextState.remoteVideoState {
            case .inactive:
                mappedRemoteVideoState = .inactive
            case .active:
                mappedRemoteVideoState = .active
            case .paused:
                mappedRemoteVideoState = .paused
            }
            switch callContextState.remoteAudioState {
            case .active:
                mappedRemoteAudioState = .active
            case .muted:
                mappedRemoteAudioState = .muted
            }
            switch callContextState.remoteBatteryLevel {
            case .normal:
                mappedRemoteBatteryLevel = .normal
            case .low:
                mappedRemoteBatteryLevel = .low
            }
            self.previousVideoState = mappedVideoState
            self.previousRemoteVideoState = mappedRemoteVideoState
            self.previousRemoteAudioState = mappedRemoteAudioState
            self.previousRemoteBatteryLevel = mappedRemoteBatteryLevel
        } else {
            if let previousVideoState = self.previousVideoState {
                mappedVideoState = previousVideoState
            } else {
                if self.videoIsForceDisabled {
                    mappedVideoState = .inactive(self.isVideoAvailable)
                } else if self.isVideo {
                    mappedVideoState = .active(self.isVideoAvailable)
                } else if self.isVideoPossible {
                    mappedVideoState = .inactive(self.isVideoAvailable)
                } else {
                    mappedVideoState = .notAvailable
                }
            }
            mappedRemoteVideoState = .inactive
            if let previousRemoteAudioState = self.previousRemoteAudioState {
                mappedRemoteAudioState = previousRemoteAudioState
            } else {
                mappedRemoteAudioState = .active
            }
            if let previousRemoteBatteryLevel = self.previousRemoteBatteryLevel {
                mappedRemoteBatteryLevel = previousRemoteBatteryLevel
            } else {
                mappedRemoteBatteryLevel = .normal
            }
        }
        
        self.remoteAudioState = mappedRemoteAudioState
        self.remoteBatteryLevel = mappedRemoteBatteryLevel
        
        switch sessionState.state {
        case .ringing:
            presentationState = CallState(state: .ringing, videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls)
        case .accepting:
            self.callWasActive = true
            presentationState = CallState(state: .connecting(nil), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls)
        case let .dropping(reason):
            presentationState = CallState(state: .terminating(reason), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls)
        case let .terminated(id, reason, options):
            presentationState = CallState(state: .terminated(id, reason, options.contains(.reportRating)), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls)
        case let .requesting(ringing):
            presentationState = CallState(state: .requesting(ringing), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: self.supportsConferenceCalls)
        case .active(_, _, _, _, _, _, _, _, _), .switchedToConference:
            self.callWasActive = true
            
            var isConference = false
            if case .switchedToConference = sessionState.state {
                isConference = true
            }
            
            var supportsConferenceCalls = false
            if case .active(_, _, _, _, _, _, _, _, supportsConferenceCalls) = sessionState.state {
                supportsConferenceCalls = true
            }
            
            if let callContextState = callContextState, !isConference, case let .active(_, _, keyVisualHash, _, _, _, _, _, _) = sessionState.state {
                switch callContextState.state {
                case .initializing:
                    presentationState = CallState(state: .connecting(keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: supportsConferenceCalls)
                case .failed:
                    presentationState = nil
                    self.callSessionManager.drop(internalId: self.internalId, reason: .disconnect, debugLog: .single(nil))
                case .connected:
                    let timestamp: Double
                    if let activeTimestamp = self.activeTimestamp {
                        timestamp = activeTimestamp
                    } else {
                        timestamp = CFAbsoluteTimeGetCurrent()
                        self.activeTimestamp = timestamp
                    }
                    presentationState = CallState(state: .active(timestamp, reception, keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: supportsConferenceCalls)
                case .reconnecting:
                    let timestamp: Double
                    if let activeTimestamp = self.activeTimestamp {
                        timestamp = activeTimestamp
                    } else {
                        timestamp = CFAbsoluteTimeGetCurrent()
                        self.activeTimestamp = timestamp
                    }
                    presentationState = CallState(state: .reconnecting(timestamp, reception, keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: supportsConferenceCalls)
                }
            } else if !isConference, case let .active(_, _, keyVisualHash, _, _, _, _, _, _) = sessionState.state {
                presentationState = CallState(state: .connecting(keyVisualHash), videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, isMuted: self.isMuted, isOutgoingVideoPaused: self.isOutgoingVideoPaused, remoteAspectRatio: self.remoteAspectRatio, remoteAudioState: self.remoteAudioState, remoteBatteryLevel: self.remoteBatteryLevel, isScreenCapture: self.isScreenCapture, participants: self.incomingParticipants, conferenceReference: self.incomingConferenceSource, supportsConferenceCalls: supportsConferenceCalls)
            }
        }
        
        
        var conferenceCallData: InternalGroupCallReference?
        if let incomingConferenceSource = self.incomingConferenceSource {
            if self.isAcceptingIncomingConference {
                conferenceCallData = .message(id: incomingConferenceSource)
            }
        } else {
            switch sessionState.state {
            case let .switchedToConference(slug):
                conferenceCallData = .link(slug: slug)
            default:
                break
            }
        }

        
        if let conferenceCallData {
            if self.conferenceCallDisposable == nil {
                let conferenceCallSignal = self.accountContext.engine.calls.getCurrentGroupCall(reference: conferenceCallData)
                self.conferenceCallDisposable = (conferenceCallSignal
                |> deliverOnMainQueue).startStrict(next: { [weak self] groupCall in
                    guard let self else {
                        return
                    }
                    let keyPair: TelegramKeyPair? = TelegramE2EEncryptionProviderImpl.shared.generateKeyPair()
                    guard let keyPair, let groupCall else {
                        self.updateSessionState(sessionState: CallSession(
                            id: self.internalId,
                            stableId: self.conferenceStableId,
                            isOutgoing: false,
                            type: .audio,
                            state: .terminated(id: nil, reason: .ended(.switchedToConference(slug: "")), options: CallTerminationOptions()),
                            isVideoPossible: true
                        ),
                        callContextState: nil, reception: nil)
                        return
                    }
                    
                    var initialOutput: GroupCallInitialOutput = .init(isMuted: self.isMuted)
                    
                    if let videoCapturer = self.videoCapturer {
                        if let screenCaptureSource {
                            initialOutput.screencast = .init(capturer: OngoingCallVideoCapturer(videoCapturer.deviceId), source: screenCaptureSource)
                        } else {
                            let device = self.devices.camera.first(where: { self.devicesContext.currentCameraId == $0.uniqueID })
                            if let device {
                                initialOutput.video = .init(capturer: OngoingCallVideoCapturer(videoCapturer.deviceId), source: CameraCaptureDevice(device))
                            }
                        }
                    }
                    
                    let conferenceCall = PresentationGroupCallImpl(
                        accountContext: self.accountContext,
                        initialCall: (EngineGroupCallDescription(
                            id: groupCall.info.id,
                            accessHash: groupCall.info.accessHash,
                            title: nil,
                            scheduleTimestamp: nil,
                            subscribedToScheduled: false,
                            isStream: false
                        ), conferenceCallData),
                        internalId: CallSessionInternalId(),
                        peerId: nil,
                        isChannel: false,
                        invite: nil,
                        joinAsPeerId: nil,
                        initialInfo: nil,
                        isStream: false,
                        keyPair: keyPair,
                        conferenceSourceId: self.internalId,
                        isConference: true,
                        initialOutput: initialOutput
                    )
                    self.conferenceCallImpl = conferenceCall
                    conferenceCall.upgradedConferenceCall = self
                    
                    for peerId in self.pendingInviteToConferencePeerIds {
                        let _ = conferenceCall.invitePeer(peerId)
                    }
                    
                    
                    
                    
                    self.conferenceStateValue = .preparing
                    
                    self.waitForConferenceCallReadyDisposable?.dispose()
                    self.waitForConferenceCallReadyDisposable = (combineLatest(queue: .mainQueue(),
                        conferenceCall.state,
                        conferenceCall.members
                    )
                    |> filter { state, members in
//                        if state.networkState != .connected {
//                            return false
//                        }
                        return true
                    }
                    |> map { _, _ -> Void in
                        return Void()
                    }
                    |> take(1)
                    |> timeout(10.0, queue: .mainQueue(), alternate: .single(Void()))).start(next: { [weak self] _ in
                        guard let self else {
                            return
                        }
                        
                        self.ongoingContextStateDisposable?.dispose()
                        
                        self.conferenceStateValue = .ready
                        
                        let upgradedToConferenceCompletions = self.upgradedToConferenceCompletions.copyItems()
                        self.upgradedToConferenceCompletions.removeAll()
                        for f in upgradedToConferenceCompletions {
                            f(conferenceCall)
                        }
                        
                        guard let window else {
                            return
                        }
                        
                        let callContext = GroupCallContext(call: conferenceCall, peerMemberContextsManager: accountContext.peerChannelMemberCategoriesContextsManager, window: window)
                        accountContext.sharedContext.dropCrossCall()
                        accountContext.sharedContext.peerCall?.contextObject = nil
                        accountContext.sharedContext.peerCall?.onCompletion?()
                        applyGroupCallResult(accountContext.sharedContext, callContext)
                        
                    })
                }, error: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.updateSessionState(sessionState: CallSession(
                        id: self.internalId,
                        stableId: self.conferenceStableId,
                        isOutgoing: false,
                        type: .audio,
                        state: .terminated(id: nil, reason: .error(.generic), options: CallTerminationOptions()),
                        isVideoPossible: true
                    ),
                    callContextState: nil, reception: nil)
                })
            }
        }

        
        
        switch sessionState.state {
        case .requesting:
            break
        case let .active(id, key, _, connections, maxLayer, version, customParameters, allowsP2P, supportsConferenceCalls):
            if !wasActive {
                let logName = "\(id.id)_\(id.accessHash)"
                
                let ongoingContext = OngoingCallContext(account: account, callSessionManager: self.callSessionManager, internalId: self.internalId, proxyServer: proxyServer, initialNetworkType: self.currentNetworkType, updatedNetworkType: self.updatedNetworkType, serializedData: self.serializedData, dataSaving: dataSaving, derivedState: self.derivedState, key: key, isOutgoing: sessionState.isOutgoing, video: self.videoCapturer, connections: connections, maxLayer: maxLayer, version: version, allowP2P: allowsP2P, enableTCP: self.enableTCP, enableStunMarking: self.enableStunMarking, logName: logName, preferredVideoCodec: self.preferredVideoCodec, inputDeviceId: self.devicesContext.currentMicroId, outputDeviceId: self.devicesContext.currentOutputId)
                self.ongoingContext = ongoingContext
                
                //                ongoingContext.switchAudioInput(self.devicesContext.currentMicroId ?? "")
                //                ongoingContext.switchAudioOutput(self.devicesContext.currentOutputId ?? "")
                
                self.audioLevelPromise.set(ongoingContext.audioLevel)
                
                if let requestedVideoAspect = self.requestedVideoAspect {
                    ongoingContext.setRequestedVideoAspect(requestedVideoAspect)
                }
                
                if let delayMuteState = self.delayMuteState {
                    self.delayMuteState = nil
                    if delayMuteState {
                        self.mute()
                    } else {
                        self.unmute()
                    }
                }
                
                self.ongoingContextStateDisposable = (ongoingContext.state
                                                      |> deliverOnMainQueue).start(next: { [weak self] contextState in
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            strongSelf.updateSessionState(sessionState: sessionState, callContextState: contextState, reception: strongSelf.reception)
                        } else {
                            strongSelf.callContextState = contextState
                        }
                    }
                })
                
                self.receptionDisposable = (ongoingContext.reception
                                            |> deliverOnMainQueue).start(next: { [weak self] reception in
                    if let strongSelf = self {
                        if let sessionState = strongSelf.sessionState {
                            strongSelf.updateSessionState(sessionState: sessionState, callContextState: strongSelf.callContextState, reception: reception)
                        } else {
                            strongSelf.reception = reception
                        }
                    }
                })
                
            }
        case let .terminated(id, _, options):
            if wasActive {
                let debugLogValue = Promise<String?>()
                self.ongoingContext?.stop(callId: id, sendDebugLogs: options.contains(.sendDebugLogs), debugLogValue: debugLogValue)
            }
        default:
            if wasActive {
                let debugLogValue = Promise<String?>()
                self.ongoingContext?.stop(debugLogValue: debugLogValue)
            }
        }
        if case let .terminated(_, reason, _) = sessionState.state, !wasTerminated {
            if !self.didSetCanBeRemoved {
                if reason.recall {
                    
                } else {
                    self.didSetCanBeRemoved = true
                    self.canBeRemovedPromise.set(.single(true) |> delay(1.6, queue: Queue.mainQueue()))
                }
            }
            self.hungUpPromise.set(true)
            if sessionState.isOutgoing {
                if !self.droppedCall {
                    let dropCallKitCallTimer = SwiftSignalKit.Timer(timeout: 1.6, repeat: false, completion: { [weak self] in
                        if let strongSelf = self {
                            strongSelf.dropCallKitCallTimer = nil
                            if !strongSelf.droppedCall {
                                strongSelf.droppedCall = true
                            }
                        }
                    }, queue: Queue.mainQueue())
                    self.dropCallKitCallTimer = dropCallKitCallTimer
                    dropCallKitCallTimer.start()
                }
            }
        }
        
        if let presentationState = presentationState {
            self.statePromise.set(presentationState)
            self.presentationState = presentationState
            self.updateTone(presentationState, callContextState: callContextState, previous: previous)
        }
        
    }
    
    private func updateTone(_ state: CallState, callContextState: OngoingCallContextState?, previous: CallSession?) {
        var tone: CallTone?
        if let callContextState = callContextState, case .reconnecting = callContextState.state {
            tone = .connecting
        } else if let previous = previous {
            switch previous.state {
            case .accepting, .active, .dropping, .requesting:
                switch state.state {
                case .connecting:
                    if case .requesting = previous.state {
                        tone = .ringback
                    } else {
                        tone = .connecting
                    }
                case .requesting(true):
                    tone = .ringback
                case let .terminated(_, reason, _):
                    if let reason = reason {
                        switch reason {
                        case let .ended(type):
                            switch type {
                            case .busy:
                                tone = .busy
                            case .hungUp, .missed:
                                tone = .ended
                            case .switchedToConference:
                                tone = nil
                            }
                        case .error:
                            tone = .failed
                        }
                    }
                case .ringing:
                    tone = .ringing
                default:
                    break
                }
            default:
                break
            }
        } else if callContextState == nil && !isOutgoing {
            tone = .ringing
        } else if callContextState == nil && isOutgoing {
            tone = .ringback
        }
        if let tone = tone {
            playTone(tone)
        } else {
            stopTone()
        }
    }
    
    
    
    deinit {
        peerDisposable.dispose()
        stateDisposable.dispose()
        drop(.disconnect)
        sessionStateDisposable.dispose()
        ongoingContextStateDisposable?.dispose()
        settingsDisposable?.dispose()
        devicesDisposable.dispose()
        devicesListDisposable.dispose()
        conferenceCallDisposable?.dispose()
    }
    
    private func playRingtone() {
        playingRingtone = true
        if let path = Bundle.main.path(forResource: "opening", ofType:"m4a") {
            playTone(URL(fileURLWithPath: path), loops: -1)
        }
        
    }
    
    
    public func requestVideo() {
        if isVideoAvailable {
            let requestVideo: Bool = self.videoCapturer == nil
            if self.videoCapturer == nil {
                let videoCapturer = OngoingCallVideoCapturer(devicesContext.currentCameraId ?? "")
                self.videoCapturer = videoCapturer
                self.videoIsForceDisabled = false
            }
            if self.isScreenCapture {
                self.videoCapturer?.switchVideoInput(devicesContext.currentCameraId ?? "")
            }
            self.isScreenCapture = false
            self.isOutgoingVideoPaused = false
            
            if let videoCapturer = self.videoCapturer, requestVideo {
                self.ongoingContext?.requestVideo(videoCapturer)
            }
            if let state = self.sessionState {
                self.updateSessionState(sessionState: state, callContextState: self.callContextState, reception: self.reception)
            }
            //            setRequestedVideoAspect(Float(System.cameraAspectRatio))
        }
    }
    
    public func enableScreenCapture(_ source: VideoSourceMac) {
        
        let id = source.deviceIdKey()
        
        let requestVideo: Bool = self.videoCapturer == nil
        if self.videoCapturer == nil {
            let videoCapturer = OngoingCallVideoCapturer(id)
            self.videoCapturer = videoCapturer
            self.videoIsForceDisabled = false
        }
        
        self.isOutgoingVideoPaused = true
        self.isScreenCapture = true
        self.screenCaptureSource = source
        
        if let videoCapturer = self.videoCapturer, requestVideo {
            self.ongoingContext?.requestVideo(videoCapturer)
        }
        if !requestVideo {
            self.videoCapturer?.switchVideoInput(id)
        }
        //        setRequestedVideoAspect(Float(System.aspectRatio))
        
        if let state = self.sessionState {
            self.updateSessionState(sessionState: state, callContextState: self.callContextState, reception: self.reception)
        }
    }
    public func disableScreenCapture() {
        self.videoCapturer?.switchVideoInput(devicesContext.currentCameraId ?? "")
        if let _ = self.videoCapturer {
            self.videoCapturer = nil
            self.ongoingContext?.disableVideo()
            self.videoIsForceDisabled = true
        }
        self.isOutgoingVideoPaused = true
        self.isScreenCapture = false
        self.screenCaptureSource = nil
        
        if let state = self.sessionState {
            self.updateSessionState(sessionState: state, callContextState: self.callContextState, reception: self.reception)
        }
    }
    
    private weak var captureSelectWindow: DesktopCapturerWindow?
    
    public func toggleScreenCapture() -> ScreenCaptureLaunchError? {
        if !self.isScreenCapture {
            if let captureSelectWindow = captureSelectWindow {
                captureSelectWindow.orderFrontRegardless()
            } else {
                self.captureSelectWindow = presentDesktopCapturerWindow(mode: .screencast, select: { [weak self] source, value in
                    self?.enableScreenCapture(source)
                }, devices: accountContext.sharedContext.devicesContext, microIsOff: self.isMuted)
            }
        } else {
            self.disableScreenCapture()
        }
        return nil
    }
    
    public func disableVideo() {
        if let _ = self.videoCapturer {
            self.videoCapturer = nil
            self.ongoingContext?.disableVideo()
            self.videoIsForceDisabled = true
        }
        self.isScreenCapture = false
        self.isOutgoingVideoPaused = true
        if let state = self.sessionState {
            self.updateSessionState(sessionState: state, callContextState: self.callContextState, reception: self.reception)
        }
    }
    
    
    public func setRequestedVideoAspect(_ aspect: Float) {
        self.requestedVideoAspect = aspect
        self.ongoingContext?.setRequestedVideoAspect(aspect)
    }
    
    
    @discardableResult func hangUpCurrentCall() -> Signal<Bool, NoError> {
        return hangUpCurrentCall(false)
    }
    
    func hangUpCurrentCall(_ external: Bool) -> Signal<Bool, NoError> {
        completed = external
        var reason:CallSessionTerminationReason = .ended(.hungUp)
        if let session = sessionState {
            if case .terminated = session.state {
                reason = session.isOutgoing ? .ended(.missed) : .ended(.busy)
            }
        }
        discardCurrentCallWithReason(reason)
        
        if callContextState == nil, let session = sessionState, session.isOutgoing {
            self.didSetCanBeRemoved = true
            self.canBeRemovedPromise.set(.single(true))
        }
        return canBeRemovedPromise.get()
    }
    
    func setToRemovableState() {
        if !self.didSetCanBeRemoved {
            self.didSetCanBeRemoved = true
        }
        self.canBeRemovedPromise.set(.single(true))
    }
    
    private func discardCurrentCallWithReason(_ reason: CallSessionTerminationReason) {
        
        let dropReason:DropCallReason?
        
        switch reason {
        case .ended(let ended):
            switch ended {
            case .busy, .missed:
                dropReason = .busy
            case .hungUp:
                dropReason = .hangUp
            case .switchedToConference:
                dropReason = nil
            }
        case .error:
            dropReason = .disconnect
        }
        if let dropReason {
            drop(dropReason)
        }
    }
    
    
    private func pathForTone(_ tone:CallTone) -> URL?
    {
        let path:String?
        switch tone
        {
        case .busy:
            path = Bundle.main.path(forResource: "voip_busy", ofType:"caf")
        case .ringback:
            path = Bundle.main.path(forResource: "voip_ringback", ofType:"caf")
        case .connecting:
            path = Bundle.main.path(forResource: "voip_connecting", ofType:"mp3")
        case .failed:
            path = Bundle.main.path(forResource: "voip_fail", ofType:"caf")
        case .ended:
            path = Bundle.main.path(forResource: "voip_end", ofType:"caf")
        case .ringing:
            path = Bundle.main.path(forResource: "opening", ofType:"m4a")
        default:
            path = nil;
        }
        if let path = path {
            return URL(fileURLWithPath: path)
        } else {
            return nil
        }
    }
    
    private func loopsForTone(_ tone:CallTone) -> Int {
        switch tone {
        case .busy:
            return 3;
        case .ringback:
            return -1
        case .connecting:
            return -1
        case .failed:
            return 1
        case .ended:
            return 1
        case .ringing:
            return -1
        default:
            return 0
        }
    }
    
    private func playTone(_ tone:URL, loops:Int, completion:(()->Void)? = nil) {
        if self.player?.tone.path != tone.path {
            self.player = CallAudioPlayer(tone, loops: loops, completion: completion)
            self.player?.play()
        }
    }
    
    private func playTone(_ tone:CallTone) {
        if let url = pathForTone(tone) {
            playTone(url, loops: loopsForTone(tone))
        }
    }
    
    private func stopTone() {
        playingRingtone = false
        player?.stop()
        player = nil
    }
    
    func makeIncomingVideoView(completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
        self.ongoingContext?.makeIncomingVideoView(completion: completion)
    }
    
    func makeOutgoingVideoView(completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
        self.videoCapturer?.makeOutgoingVideoView(completion: completion)
    }
    
    func makeVideo(isIncoming: Bool) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>? {
        if isIncoming {
            return self.ongoingContext?.video(isIncoming: isIncoming)
        } else {
            return self.videoCapturer?.video()
        }
    }
    
    func upgradeToConference(invitePeerIds: [EnginePeer.Id], completion: @escaping (PresentationGroupCall) -> Void) -> Disposable {
        if let conferenceCall = self.conferenceCall {
            completion(conferenceCall)
            return EmptyDisposable
        }
        
        self.pendingInviteToConferencePeerIds = invitePeerIds
        let index = self.upgradedToConferenceCompletions.add({ call in
            completion(call)
        })
        
        self.conferenceStateValue = .preparing
        self.callSessionManager.createConferenceIfNecessary(internalId: self.internalId)
        
        return ActionDisposable { [weak self] in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                self.upgradedToConferenceCompletions.remove(index)
            }
        }
    }
    
}

enum PCallResult {
    case success(PCallSession)
    case fail
    case samePeer(PCallSession)
}

func phoneCall(context: AccountContext, peerId:PeerId, ignoreSame:Bool = false, isVideo: Bool = false) -> Signal<PCallResult, NoError> {
    
    let signal: Signal<(Bool, Bool?), NoError>
    if isVideo {
        signal = combineLatest(queue: .mainQueue(), requestMicrophonePermission(), requestCameraPermission() |> map(Optional.init))
    } else {
        signal = combineLatest(queue: .mainQueue(), requestMicrophonePermission(), .single(nil))
    }
    
    
    var isVideoPossible = context.account.postbox.transaction { transaction -> VideoCallsConfiguration in
        let appConfiguration: AppConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? AppConfiguration.defaultValue
        return VideoCallsConfiguration(appConfiguration: appConfiguration)
    }
    |> map { callsConfiguration -> Bool in
        let isVideoPossible: Bool
        switch callsConfiguration.videoCallsSupport {
        case .disabled:
            isVideoPossible = isVideo
        case .full:
            isVideoPossible = true
        case .onlyVideo:
            isVideoPossible = isVideo
        }
        return isVideoPossible
    }
    
    isVideoPossible = combineLatest(isVideoPossible, context.account.postbox.transaction {
        ($0.getPeerCachedData(peerId: peerId) as? CachedUserData)?.videoCallsAvailable ?? true
    }) |> map {
        $0.0 && $0.1
    }
    
    let accounts = context.sharedContext.activeAccounts |> take(1)
    
    
    return combineLatest(queue: .mainQueue(), signal, isVideoPossible, accounts) |> mapToSignal { values -> Signal<PCallResult, NoError> in
        
        let (microAccess, _) = values.0
        let isVideoPossible = values.1
        let activeAccounts = values.2
        
        for account in activeAccounts.accounts {
            if account.1.peerId == peerId {
                alert(for: context.window, info: strings().callSameDeviceError)
                return .complete()
            }
        }
        if microAccess {
            return makeNewCallConfirmation(accountContext: context, newPeerId: peerId, newCallType: .call, ignoreSame: ignoreSame) |> mapToSignal { value -> Signal<Bool, NoError> in
                if ignoreSame {
                    return .single(value)
                } else {
                    return context.sharedContext.endCurrentCall()
                }
            } |> mapToSignal { _ in
                return context.account.callSessionManager.request(peerId: peerId, isVideo: isVideo, enableVideo: isVideoPossible)
            }
            |> mapToSignal { id in
                return getPrivateCallSessionData(context.account, accountManager: context.sharedContext.accountManager, peerId: peerId) |> map {
                    (id, $0)
                }
            }
            |> deliverOn(callQueue)
            |> map { id, data in
                return .success(PCallSession(accountContext: context, account: context.account, isOutgoing: true, incomingConferenceSource: nil, incomingParticipants: [], peerId: peerId, id: id, initialState: nil, startWithVideo: isVideo, isVideoPossible: isVideoPossible, data: data))
            }
        } else {
            verifyAlert_button(for: context.window, information: strings().requestAccesErrorHaveNotAccessCall, ok: strings().modalOK, cancel: "", option: strings().requestAccesErrorConirmSettings, successHandler: { result in
                switch result {
                case .thrid:
                    openSystemSettings(.microphone)
                default:
                    break
                }
            })
            return .complete()
        }
    }
}

enum CallConfirmationType {
    case call
    case voiceChat
}

func makeNewCallConfirmation(accountContext: AccountContext, newPeerId: PeerId?, newCallType: CallConfirmationType, ignoreSame: Bool = false) -> Signal<Bool, NoError> {
    if accountContext.sharedContext.hasActiveCall {
        let currentCallType: CallConfirmationType
        let currentPeerId: PeerId?
        let currentAccount: Account
        if let session = accountContext.sharedContext.getCrossAccountCallSession() {
            currentPeerId = session.peerId
            currentAccount = session.account
            currentCallType = .call
        } else if let groupCall = accountContext.sharedContext.getCrossAccountGroupCall() {
            currentPeerId = groupCall.call.peerId
            currentAccount = groupCall.call.account
            currentCallType = .voiceChat
        } else {
            fatalError("wtf")
        }
        if ignoreSame, newPeerId == currentPeerId {
            return .single(true)
        }
        let from = currentAccount.postbox.transaction { transaction in
            if let currentPeerId {
                return transaction.getPeer(currentPeerId)
            } else {
                return nil
            }
        }
        let to: Signal<Peer?, NoError>
        if let newPeerId {
            to = accountContext.account.postbox.transaction {
                return $0.getPeer(newPeerId)
            }
        } else {
            to = .single(nil)
        }
        
        return combineLatest(from, to) |> map { (from: $0, to: $1) }
        |> deliverOnMainQueue
        |> mapToSignal { values in
            let header: String
            let text: String
            switch currentCallType {
            case .call:
                header = strings().callConfirmDiscardCallHeader
            case .voiceChat:
                header = strings().callConfirmDiscardVoiceHeader
            }
            switch newCallType {
            case .call:
                switch currentCallType {
                case .call:
                    text = strings().callConfirmDiscardCallToCallText(values.from?.displayTitle ?? "", values.to?.displayTitle ?? "")
                case .voiceChat:
                    text = strings().callConfirmDiscardVoiceToCallText(values.from?.displayTitle ?? "", values.to?.displayTitle ?? "")
                }
            case .voiceChat:
                switch currentCallType {
                case .call:
                    text = strings().callConfirmDiscardCallToVoiceText(values.from?.displayTitle ?? "", values.to?.displayTitle ?? "")
                case .voiceChat:
                    text = strings().callConfirmDiscardVoiceToVoiceText(values.from?.displayTitle ?? "", values.to?.displayTitle ?? "")
                }
            }
            return verifyAlertSignal(for: accountContext.window, header: header, information: text, ok: strings().modalYes, cancel: strings().modalCancel) |> map { $0 == .basic }
        }
    } else {
        return .single(true)
    }
}
