//
//  PremiumStatusControl.swift
//  Telegram
//
//  Created by Mike Renoir on 09.08.2022.
//  Copyright © 2022 Telegram. All rights reserved.
//

import Foundation
import TGUIKit
import SwiftSignalKit
import TelegramCore
import Postbox
import QuartzCore
import AppKit
import TelegramMedia


public final class StarsEffectLayer: SimpleLayer {
    private let emitterLayer = CAEmitterLayer()
    private let emitter = CAEmitterCell()

    public override init() {
        super.init()
        
        self.addSublayer(self.emitterLayer)
    }
    
    override init(layer: Any) {
        super.init(layer: layer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setup(color: NSColor, size: CGSize) {
        emitter.name = "emitter"
        emitter.contents = NSImage(contentsOfFile: Bundle.main.path(forResource: "particle", ofType: "png")!)?._cgImage
        emitter.birthRate = 6.0
        emitter.lifetime = 1.5
        emitter.velocity = 0.1
        emitter.scale = (size.width / 32.0) * 0.12
        emitter.scaleRange = 0.02
        emitter.alphaRange = 0.1
        emitter.emissionRange = .pi * 2.0
        
        
    }
    
    public func update(color: NSColor, size: CGSize) {
        if self.emitterLayer.emitterCells == nil {
            self.setup(color: color, size: size)
        }
        
        let staticColors: [Any] = [
            color.withAlphaComponent(0.0).cgColor,
            color.withAlphaComponent(0.58).cgColor,
            color.withAlphaComponent(0.58).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
        let staticColorBehavior = createEmitterBehavior(type: "colorOverLife")
        staticColorBehavior.setValue(staticColors, forKey: "colors")
        emitter.setValue([staticColorBehavior], forKey: "emitterBehaviors")
        self.emitterLayer.emitterCells = [emitter]
        
        self.emitterLayer.seed = UInt32.random(in: .min ..< .max)
        self.emitterLayer.emitterShape = .circle
        self.emitterLayer.emitterSize = size
        self.emitterLayer.emitterMode = .surface
        self.emitterLayer.frame = CGRect(origin: .zero, size: size)
        self.emitterLayer.emitterPosition = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
    }
}



final class PremiumStatusControl : Control {
    private var imageLayer: SimpleLayer?
    private var animateLayer: InlineStickerItemLayer?
    private var statusSelected: Bool? = nil
    private var starsLayer: StarsEffectLayer?
    required init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        userInteractionEnabled = false
        layer?.masksToBounds = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private let disposable = MetaDisposable()
    
    private var lite: Bool = false
    
    override func layout() {
        super.layout()
        var offset: CGFloat = 0
        if let imageLayer = imageLayer {
            var rect = focus(imageLayer.frame.size)
            rect.origin.x = 0
            imageLayer.frame = rect
            offset += rect.maxX - 7
        }
        if let animateLayer = self.animateLayer {
            var rect = focus(animateLayer.frame.size)
            rect.origin.x = offset
            animateLayer.frame = rect
        }
    }
    
    func set(_ peer: Peer, account: Account, inlinePacksContext: InlineStickersContext?, left: Bool, color: NSColor?, isSelected: Bool, isBig: Bool, animated: Bool, playTwice: Bool = true, isLite: Bool) {
        
        
        self.lite = isLite
        
        if let size = PremiumStatusControl.controlSize(peer, isBig, left: left) {
            setFrameSize(size)
        }
        self.layer?.opacity = color != nil && peer.emojiStatus != nil ? 0.4 : 1

        if (peer.isFake || peer.isScam || peer.isPremium || peer.isVerified) && !left, ((peer.isPremium && peer.emojiStatus == nil) || !peer.isPremium || peer.isFake || peer.isScam) && !left  {

            let current: SimpleLayer
            if let layer = self.imageLayer {
                current = layer
            } else {
                current = SimpleLayer()
                current.masksToBounds = false
                self.imageLayer = current
                self.layer?.addSublayer(current)
            }
            let image: CGImage?
            
            if peer.isVerified {
                image = isSelected ? (left ? theme.icons.verify_dialog_active_left : theme.icons.verifyDialogActive) : (left ? theme.icons.verify_dialog_left : theme.icons.verifyDialog)
            } else if peer.isScam {
                image = isSelected ? theme.icons.scamActive : theme.icons.scam
            } else if peer.isFake {
                image = isSelected ? theme.icons.fakeActive : theme.icons.fake
            } else if peer.isPremium {
                if isBig {
                    let color = color ?? theme.colors.accent
                    if isSelected {
                        let under = theme.colors.underSelectedColor
                        image = theme.resourceCache.image(Int32(color.rgb + 1000), {
                            generatePremium(false, color: under)
                        })
                    } else {
                        image = theme.resourceCache.image(Int32(color.rgb + 1001), {
                            generatePremium(false, color: color)
                        })
                    }
                } else {
                    if isSelected {
                        let under = theme.colors.underSelectedColor
                        image = theme.resourceCache.image(Int32(under.rgb + 1003), {
                            return generatePremium(false, color: under, small: true)
                        })
                    } else if let color = color {
                        image = theme.resourceCache.image(Int32(color.rgb + 1002), {
                            return generatePremium(false, color: color, small: true)
                        })
                    } else {
                        let under = theme.colors.accent
                        image = theme.resourceCache.image(Int32(under.rgb + 1004), {
                            return generatePremium(false, color: under, small: true)
                        })
                    }
                }
            } else {
                image = nil
            }
            if let image = image {
                current.contents = image
                current.contentsScale = System.backingScale
                current.contentsGravity = .resizeAspectFill
                var rect = focus(image.backingSize)
                rect.origin.x = 0
                current.frame = rect
            } else {
                current.contents = nil
            }
        } else if let imageLayer = imageLayer {
            performSublayerRemoval(imageLayer, animated: animated, scale: true)
            self.imageLayer = nil
        }
        
        let makeStatus:(Int64)->Void = { [weak self] fileId in
            guard let self else {
                return
            }
            let current: InlineStickerItemLayer
            
            let getColors:(TelegramMediaFile?)->[LottieColor] = { file in
                var colors: [LottieColor] = []
                if let file = file {
                    if isDefaultStatusesPackId(file.emojiReference) || file.paintToText {
                        if isSelected {
                            colors.append(.init(keyPath: "", color: theme.colors.underSelectedColor))
                        } else {
                            colors.append(.init(keyPath: "", color: color ?? theme.colors.accent))
                        }
                    }
                }
                return colors
            }
            
            var updated: Bool = false
            
            if statusSelected != isSelected, let layer = self.animateLayer {
                if layer.file?.fileId.id == fileId {
                    if !getColors(layer.file).isEmpty {
                        updated = true
                    }
                }
            }
            
            if let layer = self.animateLayer, layer.file?.fileId.id == fileId && !updated {
                current = layer
                if isDefaultStatusesPackId(layer.file?.emojiReference), color != nil {
                    self.layer?.opacity = Float(alphaValue)
                } else {
                    self.layer?.opacity = Float(alphaValue)
                }
                
            } else {
                let animated = animated && statusSelected == isSelected
                var previousStopped: Bool = false
                if self.animateLayer?.file?.fileId.id == fileId {
                    previousStopped = self.animateLayer?.stopped ?? false
                }
                if let animateLayer = animateLayer {
                    performSublayerRemoval(animateLayer, animated: animated, scale: true)
                    self.animateLayer = nil
                }
                current = InlineStickerItemLayer(account: account, inlinePacksContext: inlinePacksContext, emoji: .init(fileId: fileId, file: nil, emoji: ""), size: frame.size, playPolicy: isBig && !playTwice ? .loop : .playCount(2), checkStatus: true, getColors: getColors)
                
                current.fileDidUpdate = { [weak self] file in
                    guard let `self` = self else {
                        return
                    }
                    if isDefaultStatusesPackId(file?.emojiReference), color != nil {
                        self.layer?.opacity = 0.4
                    } else {
                        self.layer?.opacity = Float(self.alphaValue)
                    }
                }
                current.fileDidUpdate?(current.file)
                
                current.stopped = previousStopped
                current.superview = self
                self.animateLayer = current
                self.layer?.addSublayer(current)
                
                if animated {
                    current.animateAlpha(from: 0, to: 1, duration: 0.2)
                    current.animateScale(from: 0.1, to: 1, duration: 0.2)
                }
            }
        }
        
        if let status = peer.emojiStatus, !peer.isFake && !peer.isScam, !left {
            let fileId: Int64 = status.fileId
            makeStatus(fileId)
        } else if let status = peer.verificationIconFileId, left {
            let fileId: Int64 = status
            makeStatus(fileId)
        } else if let animateLayer = animateLayer {
            performSublayerRemoval(animateLayer, animated: animated)
            self.animateLayer = nil
        }
        
        if let status = peer.emojiStatus, case let .starGift(_, _, title, _, _, innerColor, _, _, _) = status.content, !left {
            let starsLayer: StarsEffectLayer
            if let current = self.starsLayer {
                starsLayer = current
            } else {
                starsLayer = StarsEffectLayer()
                self.layer?.insertSublayer(starsLayer, at: 0)
                self.starsLayer = starsLayer
            }
            let availableSize = NSMakeSize(20, 20)
            let side = floor(availableSize.width * 1.25)
            let starsFrame = CGRect(origin: .zero, size: availableSize).focus(CGSize(width: side, height: side))
            starsLayer.frame = starsFrame
            starsLayer.update(color: isSelected ? theme.colors.underSelectedColor : NSColor(UInt32(innerColor)), size: starsFrame.size)
            
           // self.appTooltip = title
            
        } else {
            if let starsLayer = self.starsLayer {
                self.starsLayer = nil
                starsLayer.removeFromSuperlayer()
            }
            self.appTooltip = nil
        }
        

        
        self.statusSelected = isSelected
        
        self.updateAnimatableContent()
        self.updateListeners()
        
        needsLayout = true
        
        
        let updatedPeer = account.postbox.combinedView(keys: [.basicPeer(peer.id)]) |> map { view in
            return (view.views[.basicPeer(peer.id)] as? BasicPeerView)?.peer
        }
        |> filter { $0 != nil }
        |> map { $0! }
        |> deliverOnMainQueue
        
        self.disposable.set(updatedPeer.start(next: { [weak self] updated in
            if !updated.isEqual(peer) {
                self?.set(updated, account: account, inlinePacksContext: inlinePacksContext, left: left, color: color, isSelected: isSelected, isBig: isBig, animated: animated, playTwice: playTwice, isLite: isLite)
            }
        }))
    }
    

    
    @objc func updateAnimatableContent() -> Void {
        if let layer = self.animateLayer, let superview = layer.superview {
            var isKeyWindow: Bool = false
            if let window = window {
                if !window.canBecomeKey {
                    isKeyWindow = true
                } else {
                    isKeyWindow = window.isKeyWindow
                }
            }
            layer.isPlayable = NSIntersectsRect(layer.frame, superview.visibleRect) && isKeyWindow && !lite
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.updateListeners()
        self.updateAnimatableContent()
    }
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.updateListeners()
        self.updateAnimatableContent()
    }
    
    deinit {
        self.disposable.dispose()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func updateListeners() {
        let center = NotificationCenter.default
        if let window = window {
            center.removeObserver(self)
            center.addObserver(self, selector: #selector(updateAnimatableContent), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(updateAnimatableContent), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(updateAnimatableContent), name: NSView.boundsDidChangeNotification, object: self.enclosingScrollView?.contentView)
            center.addObserver(self, selector: #selector(updateAnimatableContent), name: NSView.frameDidChangeNotification, object: self.enclosingScrollView?.documentView)
            center.addObserver(self, selector: #selector(updateAnimatableContent), name: NSView.frameDidChangeNotification, object: self)
        } else {
            center.removeObserver(self)
        }
    }
    
    static func control(_ peer: Peer, account: Account, inlinePacksContext: InlineStickersContext?, left: Bool, isSelected: Bool, isBig: Bool = false, playTwice: Bool = false, color: NSColor? = nil, cached: PremiumStatusControl?, animated: Bool) -> PremiumStatusControl? {
        var current: PremiumStatusControl? = nil
        if (peer.isVerified || peer.isScam || peer.isFake || peer.isPremium || peer.emojiStatus != nil) && !left || (left && peer.verificationIconFileId != nil) {
            current = cached ?? PremiumStatusControl(frame: .zero)
        }
                
        current?.set(peer, account: account, inlinePacksContext: inlinePacksContext, left: left, color: color, isSelected: isSelected, isBig: isBig, animated: animated, playTwice: playTwice, isLite: isLite(.emoji))
        return current
    }
    
    static func hasControl(_ peer: Peer, left: Bool) -> Bool {
        return (peer.isVerified || peer.isScam || peer.isFake || peer.isPremium || peer.emojiStatus != nil) && !left || (left && peer.verificationIconFileId != nil)
    }
    static func controlSize(_ peer: Peer, _ isBig: Bool, left: Bool) -> NSSize? {
        if hasControl(peer, left: left) {
            var addition: NSSize = .zero
            if peer.isScam || peer.isFake {
                addition.width += 20
            }
            if peer.isVerified && peer.emojiStatus != nil {
                addition.width += 18
            }
            return isBig ? NSMakeSize(20 + addition.width, 20 + addition.height) : NSMakeSize(16 + addition.width, 16 + addition.height)
        } else {
            return nil
        }
    }
}
