//
//  HintModeController.swift
//  Vimac
//
//  Created by Dexter Leng on 21/3/21.
//  Copyright © 2021 Dexter Leng. All rights reserved.
//

import Cocoa
import RxSwift
import os
import Segment

extension NSEvent {
    static func localEventMonitor(matching: EventTypeMask) -> Observable<NSEvent> {
        Observable.create({ observer in
            let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: matching, handler: { event -> NSEvent? in
                observer.onNext(event)
                // return nil to prevent the event from being dispatched
                // this removes the "doot doot" sound when typing with CMD / CTRL held down
                return nil
            })!

            let cancel = Disposables.create {
                NSEvent.removeMonitor(keyMonitor)
            }
            return cancel
        })
    }
}

enum HintModeInputIntent {
    case rotate
    case exit
    case backspace
    case advance(by: String, action: HintAction)

    static func from(event: NSEvent) -> HintModeInputIntent? {
        if event.type != .keyDown { return nil }
        if event.keyCode == kVK_Escape { return .exit }
        if event.keyCode == kVK_Delete { return .backspace }
        if event.keyCode == kVK_Space { return .rotate }

        if let characters = event.charactersIgnoringModifiers {
            let action: HintAction = {
                if (event.modifierFlags.rawValue & NSEvent.ModifierFlags.shift.rawValue == NSEvent.ModifierFlags.shift.rawValue) {
                    return .rightClick
                } else if (event.modifierFlags.rawValue & NSEvent.ModifierFlags.command.rawValue == NSEvent.ModifierFlags.command.rawValue) {
                    return .doubleLeftClick
                } else {
                    return .leftClick
                }
            }()
            return .advance(by: characters, action: action)
        }

        return nil
    }
}

// a view controller that has a single view controller child that can be swapped out.
class ContentViewController: NSViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func loadView() {
        self.view = NSView()
    }

    func setChildViewController(_ vc: NSViewController) {
        assert(self.children.count <= 1)
        removeChildViewController()

        self.addChild(vc)
        vc.view.frame = self.view.frame
        self.view.addSubview(vc.view)
    }

    func removeChildViewController() {
        guard let childVC = self.children.first else { return }
        childVC.view.removeFromSuperview()
        childVC.removeFromParent()
    }
}

struct Hint {
    let element: Element
    let text: String
}

enum HintAction {
    case leftClick
    case rightClick
    case doubleLeftClick
}

class HintModeUserInterface {
    let frame: NSRect
    let windowController: OverlayWindowController
    let contentViewController: ContentViewController
    var hintsViewController: HintsViewController?

    let textSize = UserPreferences.HintMode.TextSizeProperty.readAsFloat()

    init(frame: NSRect) {
        self.frame = frame
        self.windowController = OverlayWindowController()
        self.contentViewController = ContentViewController()
        self.windowController.window?.contentViewController = self.contentViewController
        self.windowController.fitToFrame(frame)
    }

    func show() {
        self.windowController.showWindow(nil)
        self.windowController.window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        self.contentViewController.view.removeFromSuperview()
        self.windowController.window?.contentViewController = nil
        self.windowController.close()
    }

    func setHints(hints: [Hint]) {
        self.hintsViewController = HintsViewController(hints: hints, textSize: CGFloat(textSize), typed: "")
        self.contentViewController.setChildViewController(self.hintsViewController!)
    }

    func updateInput(input: String) {
        guard let hintsViewController = self.hintsViewController else { return }
        hintsViewController.updateTyped(typed: input)
    }

    func rotateHints() {
        guard let hintsViewController = self.hintsViewController else { return }
        hintsViewController.rotateHints()
    }
}

class HintModeController: ModeController {
    weak var delegate: ModeControllerDelegate?
    private var activated = false
    
    private let startTime = CFAbsoluteTimeGetCurrent()
    private let disposeBag = DisposeBag()

    let hintCharacters = UserPreferences.HintMode.CustomCharactersProperty.read()
    
    private var ui: HintModeUserInterface!
    private var input: String!
    private var hints: [Hint]!
    
    let app: NSRunningApplication?
    let window: Element?
    
    init(app: NSRunningApplication?, window: Element?) {
        self.app = app
        self.window = window
    }

    func activate() {
        if activated { return }
        activated = true
        
        let screenFrame: NSRect = {
            if let window = window {
                let focusedWindowFrame: NSRect = GeometryUtils.convertAXFrameToGlobal(window.frame)
                let screenFrame = activeScreenFrame(focusedWindowFrame: focusedWindowFrame)
                return screenFrame
            }
            return NSScreen.main!.frame
        }()
        
        HideCursorGlobally.hide()
        
        self.input = ""
        self.ui = HintModeUserInterface(frame: screenFrame)
        self.ui.show()
        
        self.queryHints(
            onSuccess: { [weak self] hints in
                self?.onHintQuerySuccess(hints: hints)
            },
            onError: { [weak self] e in
                self?.deactivate()
            }
        )
    }
    
    func deactivate() {
        if !activated { return }
        activated = false
        
        Analytics.shared().track("Hint Mode Deactivated", properties: [
            "Target Application": self.app?.bundleIdentifier as Any
        ])
        
        HideCursorGlobally.unhide()
        
        self.ui!.hide()
        self.ui = nil
        
        self.delegate?.modeDeactivated(controller: self)
    }
    
    func onHintQuerySuccess(hints: [Hint]) {
        self.hints = hints
        ui.setHints(hints: hints)
        
        listenForKeyPress(onEvent: { [weak self] event in
            self?.onKeyPress(event: event)
        })
    }
    
    private func onKeyPress(event: NSEvent) {
        guard let intent = HintModeInputIntent.from(event: event) else { return }

        switch intent {
        case .exit:
            self.deactivate()
        case .rotate:
            Analytics.shared().track("Hint Mode Rotated Hints", properties: [
                "Target Application": self.app?.bundleIdentifier as Any
            ])
            self.ui.rotateHints()
        case .backspace:
            _ = self.input.popLast()
            ui.updateInput(input: input)
        case .advance(let by, let action):
            self.input = self.input + by
            let hintsWithInputAsPrefix = hints.filter { $0.text.starts(with: input.uppercased()) }

            if hintsWithInputAsPrefix.count == 0 {
                Analytics.shared().track("Hint Mode Deadend", properties: [
                    "Target Application": app?.bundleIdentifier as Any
                ])
                self.deactivate()
                return
            }

            let matchingHint = hintsWithInputAsPrefix.first(where: { $0.text == input.uppercased() })

            if let matchingHint = matchingHint {
                Analytics.shared().track("Hint Mode Action Performed", properties: [
                    "Target Application": app?.bundleIdentifier as Any
                ])
                
                self.deactivate()
                performHintAction(matchingHint, action: action)
                return
            }

            ui.updateInput(input: self.input)
        }
    }
    
    private func queryHints(onSuccess: @escaping ([Hint]) -> Void, onError: @escaping (Error) -> Void) {
        HintModeQueryService.init(app: app, window: window, hintCharacters: hintCharacters).perform()
            .toArray()
            .observeOn(MainScheduler.instance)
            .do(onSuccess: { _ in self.logQueryTime() })
            .do(onError: { e in self.logError(e) })
            .subscribe(
                onSuccess: { onSuccess($0) },
                onError: { onError($0) }
            )
            .disposed(by: disposeBag)
    }

    private func listenForKeyPress(onEvent: @escaping (NSEvent) -> Void) {
        NSEvent.localEventMonitor(matching: .keyDown)
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { event in
                onEvent(event)
            })
            .disposed(by: disposeBag)
    }
    
    private func activeScreenFrame(focusedWindowFrame: NSRect) -> NSRect {
        // When the focused window is in full screen mode in a secondary display,
        // NSScreen.main will point to the primary display.
        // this is a workaround.
        var activeScreen = NSScreen.main!
        var maxArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(focusedWindowFrame)
            let area = intersection.width * intersection.height
            if area > maxArea {
                maxArea = area
                activeScreen = screen
            }
        }
        return activeScreen.frame
    }
    
    private func performHintAction(_ hint: Hint, action: HintAction) {
        let element = hint.element

        let frame = element.clippedFrame ?? element.frame
        let position = frame.origin
        let size = frame.size

        let centerPositionX = position.x + (size.width / 2)
        let centerPositionY = position.y + (size.height / 2)
        let centerPosition = NSPoint(x: centerPositionX, y: centerPositionY)

        Utils.moveMouse(position: centerPosition)

        switch action {
        case .leftClick:
            Utils.leftClickMouse(position: centerPosition)
        case .rightClick:
            Utils.rightClickMouse(position: centerPosition)
        case .doubleLeftClick:
            Utils.doubleLeftClickMouse(position: centerPosition)
        }
    }
    
    private func logQueryTime() {
        let timeElapsed = CFAbsoluteTimeGetCurrent() - self.startTime
        os_log("[Hint mode] query time: %@", log: Log.accessibility, String(describing: timeElapsed))
    }

    private func logError(_ e: Error) {
        os_log("[Hint mode] query error: %@", log: Log.accessibility, String(describing: e))
    }
}
