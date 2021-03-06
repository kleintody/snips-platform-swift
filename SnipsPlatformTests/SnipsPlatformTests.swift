//
//  SnipsPlatformTests.swift
//  SnipsPlatformTests
//
//  Copyright © 2019 Snips. All rights reserved.
//

import XCTest
import AVFoundation
@testable import SnipsPlatform

let kHotwordAudioFile = "hey_snips"
let kWeatherAudioFile = "what_will_be_the_weather_in_Madagascar_in_two_days"
let kWonderlandAudioFile = "what_will_be_the_weather_in_Wonderland"
let kPlayMJAudioFile = "hey_snips_can_you_play_me_some_Michael_Jackson"
let kFrameCapacity: AVAudioFrameCount = 256
let testTimeout = 60.0

class SnipsPlatformTests: XCTestCase {
    var snips: SnipsPlatform?
    
    var onIntentDetected: ((IntentMessage) -> ())?
    var onHotwordDetected: (() -> ())?
    var speechHandler: ((SayMessage) -> ())?
    var onSessionStartedHandler: ((SessionStartedMessage) -> ())?
    var onSessionQueuedHandler: ((SessionQueuedMessage) -> ())?
    var onSessionEndedHandler: ((SessionEndedMessage) -> ())?
    var onListeningStateChanged: ((Bool) -> ())?
    var onIntentNotRecognizedHandler: ((IntentNotRecognizedMessage) -> ())?
    var onTextCapturedHandler: ((TextCapturedMessage) -> ())?
    var onPartialTextCapturedHandler: ((TextCapturedMessage) -> ())?
    var onInjectionCompleteHandler: ((InjectionCompleteMessage) -> ())?
    var onInjectionResetCompleteHandler: ((InjectionResetCompleteMessage) -> ())?
    
    let soundQueue = DispatchQueue(label: "ai.snips.SnipsPlatformTests.sound", qos: .userInteractive)
    var firstTimePlayedAudio: Bool = true
    
    // MARK: - XCTestCase lifecycle
    
    override func setUp() {
        super.setUp()
        try! setupSnipsPlatform()
    }

    override func tearDown() {
        super.tearDown()
        // TODO workaround to wait for the asr thread to stop, cf snips-megazord/src/lib.rs#L538
        Thread.sleep(forTimeInterval: 5)
        try! stopSnipsPlatform()
    }

    // MARK: - Tests
    
    func test_hotword() {
        let hotwordDetectedExpectation = expectation(description: "Hotword detected")
        let sessionEndedExpectation = expectation(description: "Session ended")

        onHotwordDetected = hotwordDetectedExpectation.fulfill
        onSessionStartedHandler = { [weak self] sessionStarted in
            try! self?.snips?.endSession(sessionId: sessionStarted.sessionId)
        }
        onSessionEndedHandler = { _ in
            sessionEndedExpectation.fulfill()
        }

        playAudio(forResource: kHotwordAudioFile)

        wait(for: [hotwordDetectedExpectation, sessionEndedExpectation], timeout: testTimeout)
    }
    
    func test_intent() {
        let countrySlotExpectation = expectation(description: "City slot")
        let timeSlotExpectation = expectation(description: "Time slot")
        let sessionEndedExpectation = expectation(description: "Session ended")
        let alternativeIntentsExpectation = expectation(description: "Alternative intents")
        
        onListeningStateChanged = { [weak self] isListening in
            if isListening {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }
        onIntentDetected = { [weak self] intent in
            XCTAssertEqual(intent.input, "what will be the weather in madagascar in two days")
            XCTAssertEqual(intent.intent.intentName, "searchWeatherForecast")
            XCTAssertEqual(intent.slots.count, 2)

            if !intent.alternativeIntents.isEmpty {
                alternativeIntentsExpectation.fulfill()
            }
            
            intent.slots.forEach { slot in
                if slot.slotName.contains("forecast_country") {
                    if case .custom(let country) = slot.value {
                        XCTAssertEqual(country, "Madagascar")
                        countrySlotExpectation.fulfill()
                    }
                } else if slot.slotName.contains("forecast_start_datetime") {
                    if case .instantTime(let instantTime) = slot.value {
                        XCTAssertEqual(instantTime.precision, .exact)
                        XCTAssertEqual(instantTime.grain, .day)
                        let dateInTwoDays = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withTimeZone, .withDashSeparatorInDate, .withSpaceBetweenDateAndTime]
                        let instantTimeDate = formatter.date(from: instantTime.value)
                        XCTAssertEqual(Calendar.current.compare(dateInTwoDays!, to: instantTimeDate!, toGranularity: .day), .orderedSame)
                        timeSlotExpectation.fulfill()
                    }
                }
            }
            try! self?.snips?.endSession(sessionId: intent.sessionId)
        }
        onSessionEndedHandler = { _ in
            sessionEndedExpectation.fulfill()
        }

        try! self.snips?.startSession(intentFilter: nil, canBeEnqueued: true)
        
        wait(for: [countrySlotExpectation, timeSlotExpectation, sessionEndedExpectation, alternativeIntentsExpectation], timeout: testTimeout)
    }
    
    func test_intent_not_recognized() {
        let onIntentNotRecognizedExpectation = expectation(description: "Intent was not recognized")

        onListeningStateChanged = { [weak self] isListening in
            if isListening {
                self?.playAudio(forResource: kPlayMJAudioFile)
            }
        }
        onIntentNotRecognizedHandler = { [weak self] message in
            onIntentNotRecognizedExpectation.fulfill()
            try! self?.snips?.endSession(sessionId: message.sessionId)
        }

        try! self.snips?.startSession(canBeEnqueued: false, sendIntentNotRecognized: true)
        wait(for: [onIntentNotRecognizedExpectation], timeout: testTimeout)
    }

    func test_empty_intent_filter_intent_not_recognized() {
        let intentNotRecognizedExpectation = expectation(description: "Intent not recognized")

        onListeningStateChanged = { [weak self] isListening in
            if isListening {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }
        onSessionEndedHandler = { sessionEndedMessage in
            XCTAssertEqual(sessionEndedMessage.sessionTermination.terminationType, .intentNotRecognized)
            intentNotRecognizedExpectation.fulfill()
        }

        try! snips?.startSession(intentFilter: [], canBeEnqueued: false)
        waitForExpectations(timeout: testTimeout)
    }
    
    func test_unknown_intent_filter_error() {
        let intentNotRecognizedExpectation = expectation(description: "Error")
        
        onListeningStateChanged = { [weak self] isListening in
            if isListening {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }
        onSessionEndedHandler = { sessionEndedMessage in
            XCTAssertEqual(sessionEndedMessage.sessionTermination.terminationType, .error)
            intentNotRecognizedExpectation.fulfill()
        }
        
        try! snips?.startSession(intentFilter: ["nonExistentIntent"], canBeEnqueued: false)
        waitForExpectations(timeout: testTimeout)
    }

    func test_intent_filter() {
        let intentRecognizedExpectation = expectation(description: "Intent recognized")

        onListeningStateChanged = { [weak self] isListening in
            if isListening {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }
        onIntentDetected = { [weak self] intent in
            try! self?.snips?.endSession(sessionId: intent.sessionId)
            intentRecognizedExpectation.fulfill()
        }

        try! snips?.startSession(intentFilter: ["searchWeatherForecast"], canBeEnqueued: false)
        waitForExpectations(timeout: testTimeout)
    }

    func test_listening_state_changed_on() {
        let listeningStateChangedOn = expectation(description: "Listening state turned on")

        onListeningStateChanged = { state in
            if state {
                listeningStateChangedOn.fulfill()
            }
        }
        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }

        try! snips?.startSession(intentFilter: nil, canBeEnqueued: false)
        wait(for: [listeningStateChangedOn], timeout: testTimeout)
    }

    func test_listening_state_changed_off() {
        let listeningStateChangedOff = expectation(description: "Listening state turned off")
        var fullfilled = false
        onListeningStateChanged = { state in
            // we can receive multiple Listening state turned off, only fullfill once
            if !state && !fullfilled {
                listeningStateChangedOff.fulfill()
                fullfilled = true
            }
        }
        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }
        
        try! snips?.startSession(intentFilter: nil, canBeEnqueued: false)
        wait(for: [listeningStateChangedOff], timeout: testTimeout)
    }

    func test_session_notification() {
        let notificationSentExpectation = expectation(description: "Notification sent")
        let notificationStartMessage = StartSessionMessage(initType: .notification(text: "Notification text"), customData: "Notification custom data", siteId: "iOS notification")

        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            XCTAssertEqual(sessionStartedMessage.siteId, notificationStartMessage.siteId)
            XCTAssertEqual(sessionStartedMessage.customData, notificationStartMessage.customData)
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }
        onSessionEndedHandler = { _ in
            notificationSentExpectation.fulfill()
        }

        try! snips?.startSession(message: notificationStartMessage)
        waitForExpectations(timeout: testTimeout)
    }

    func test_session_notification_nil() {
        let notificationSentExpectation = expectation(description: "Notification sent")
        let notificationStartMessage = StartSessionMessage(initType: .notification(text: "Notification text"), customData: nil, siteId: nil)

        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }
        onSessionEndedHandler = { _ in
            notificationSentExpectation.fulfill()
        }

        try! snips?.startSession(message: notificationStartMessage)
        waitForExpectations(timeout: testTimeout)
    }

    func test_session_action() {
        let actionSentExpectation = expectation(description: "Action sent")
        let actionStartSessionMessage = StartSessionMessage(initType: .action(text: "Action!", intentFilter: nil, canBeEnqueued: false, sendIntentNotRecognized: false), customData: "Action Custom data", siteId: "iOS action")

        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            XCTAssertEqual(sessionStartedMessage.customData, actionStartSessionMessage.customData)
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }
        onSessionEndedHandler = { _ in
            actionSentExpectation.fulfill()
        }

        try! snips?.startSession(message: actionStartSessionMessage)
        waitForExpectations(timeout: testTimeout)
    }

    func test_session_action_nil() {
        let actionSentExpectation = expectation(description: "Action sent")
        let actionStartSessionMessage = StartSessionMessage(initType: .action(text: nil, intentFilter: nil, canBeEnqueued: false, sendIntentNotRecognized: false), customData: nil, siteId: nil)

        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            XCTAssertEqual(sessionStartedMessage.customData, actionStartSessionMessage.customData)
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }
        onSessionEndedHandler = { _ in
            actionSentExpectation.fulfill()
        }
        try! snips?.startSession(message: actionStartSessionMessage)
        waitForExpectations(timeout: testTimeout)
    }

    func test_speech_handler() {
        let speechExpectation = expectation(description: "Testing speech")
        let messageToSpeak = "Testing speech"

        speechHandler = { [weak self] sayMessage in
            XCTAssertEqual(sayMessage.text, messageToSpeak)
            guard let sessionId = sayMessage.sessionId else {
                XCTFail("Message should have a session Id since it was sent from a notification")
                return
            }
            try! self?.snips?.notifySpeechEnded(messageId: sayMessage.messageId, sessionId: sessionId)
            try! self?.snips?.endSession(sessionId: sessionId)
            speechExpectation.fulfill()
        }

        try! snips?.startNotification(text: messageToSpeak)
        waitForExpectations(timeout: testTimeout)
    }

    func test_dialog_scenario() {
        let startSessionMessage = StartSessionMessage(initType: .notification(text: "Notification"), customData: "foobar", siteId: "iOS")
        var continueSessionMessage: ContinueSessionMessage?
        var hasSentContinueSessionMessage = false
        let sessionEndedExpectation = expectation(description: "Session ended")

        onSessionStartedHandler = { [weak self] sessionStartedMessage in
            try! self?.snips?.endSession(sessionId: sessionStartedMessage.sessionId)
        }
        onSessionEndedHandler = { [weak self] sessionEndedMessage in
            XCTAssertEqual(sessionEndedMessage.sessionTermination.terminationType, .nominal)

            if !hasSentContinueSessionMessage {
                hasSentContinueSessionMessage = true
                continueSessionMessage = ContinueSessionMessage(sessionId: sessionEndedMessage.sessionId, text: "Continue session", intentFilter: nil)
                try! self?.snips?.continueSession(message: continueSessionMessage!)
                self?.playAudio(forResource: kHotwordAudioFile)
            }
            else {
                sessionEndedExpectation.fulfill()
            }
        }

        try! snips?.startSession(message: startSessionMessage)
        waitForExpectations(timeout: testTimeout)
    }

    func test_injection() {
        enum TestPhaseKind {
            case entityNotInjectedShouldNotBeDetected
            case injectingEntities
            case resetting
            case entityInjectedShouldBeDetected
            case entityInjectedShouldNotBeDetectedAfterReset
        }
        
        let entityNotInjectedShouldNotBeDetectedExpectation = expectation(description: "Entity not injected was not detected")
        let injectingEntitiesExpectation = expectation(description: "Injecting entities done")
        let entityInjectedShouldBeDetectedExpectation = expectation(description: "Entity injected was detected")
        let entityInjectedShouldNotBeDetectedAfterResetExpectation = expectation(description: "Entity injected should not be detected")
        let injectionResetDoneExpectation = expectation(description: "Injection reset request done")
        
        var testPhase: TestPhaseKind = .entityNotInjectedShouldNotBeDetected
        
        let injectionBlock = { [weak self] in
            let operation = InjectionRequestOperation(entities: ["locality": ["wonderland"], "region": ["wonderland"]], kind: .add)
            do {
                try self?.snips?.requestInjection(with: InjectionRequestMessage(operations: [operation]))
            } catch {
                XCTFail("Injection failed, reason: \(error)")
            }
        }
        
        let injectionResetBlock = { [weak self] in
            do {
                try self?.snips?.requestInjectionReset()
            } catch {
                XCTFail("Injection reset failed, reason: \(error)")
            }
        }
        
        onListeningStateChanged = { [weak self] isListening in
            if isListening {
                switch testPhase {
                case .entityNotInjectedShouldNotBeDetected, .entityInjectedShouldBeDetected, .entityInjectedShouldNotBeDetectedAfterReset:
                    self?.playAudio(forResource: kWonderlandAudioFile)
                    break
                case .injectingEntities, .resetting: XCTFail("For test purposes, shouldn't start listening in this state")
                }
            }
        }
        
        onIntentDetected = { [weak self] intentMessage in
            let slotLocalityWonderland = intentMessage.slots.filter { $0.entity == "locality" && $0.rawValue == "wonderland" }
            
            switch testPhase {
            case .entityNotInjectedShouldNotBeDetected:
                XCTAssertEqual(slotLocalityWonderland.count, 0, "should not have found any slot")
                entityNotInjectedShouldNotBeDetectedExpectation.fulfill()
                try! self?.snips?.endSession(sessionId: intentMessage.sessionId)
                testPhase = .injectingEntities
                injectionBlock()
                
            case .entityInjectedShouldBeDetected:
                XCTAssertEqual(slotLocalityWonderland.count, 1, "should have found the slot wonderland")
                entityInjectedShouldBeDetectedExpectation.fulfill()
                try! self?.snips?.endSession(sessionId: intentMessage.sessionId)
                testPhase = .resetting
                injectionResetBlock()
                
            case .injectingEntities, .resetting: XCTFail("For test purposes, intents shouldn't be detected while injecting")
                
            case .entityInjectedShouldNotBeDetectedAfterReset:
                XCTAssertEqual(slotLocalityWonderland.count, 0, "should not have found any slot")
                entityInjectedShouldNotBeDetectedAfterResetExpectation.fulfill()
                try! self?.snips?.endSession(sessionId: intentMessage.sessionId)
            }
        }
        
        onInjectionCompleteHandler = { [weak self] injectionComplete in
            injectingEntitiesExpectation.fulfill()
            testPhase = .entityInjectedShouldBeDetected
            try! self?.snips?.startSession()
        }
        
        onInjectionResetCompleteHandler = { [weak self] injectionResetComplete in
            injectionResetDoneExpectation.fulfill()
            testPhase = .entityInjectedShouldNotBeDetectedAfterReset
            try! self?.snips?.startSession()
        }
        
        try! self.snips?.startSession()
        
        wait(
            for: [
                entityNotInjectedShouldNotBeDetectedExpectation,
                injectingEntitiesExpectation,
                entityInjectedShouldBeDetectedExpectation,
                injectionResetDoneExpectation,
                entityInjectedShouldNotBeDetectedAfterResetExpectation
            ],
            timeout: 100,
            enforceOrder: true
        )
    }

    func test_asr_text_captured_handler() {
        let onTextCaptured = expectation(description: "ASR Text was captured")

        onSessionStartedHandler = { [weak self] message in
            DispatchQueue.main.sync {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }

        onTextCapturedHandler = { message in
            if message.text == "what will be the weather in madagascar in two days" {
                onTextCaptured.fulfill()
            } else {
                XCTFail("Text captured wasn't equal to the text sent")
            }
        }

        try! snips?.startSession(text: nil, intentFilter: nil, canBeEnqueued: false, sendIntentNotRecognized: true, customData: nil, siteId: nil)

        wait(for: [onTextCaptured], timeout: testTimeout)
    }
    
    func test_asr_partial_text_captured_handler() {
        let onTextCaptured = expectation(description: "Partial ASR Text was captured")

        onSessionStartedHandler = { [weak self] message in
            DispatchQueue.main.sync {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }

        onPartialTextCapturedHandler = { message in
            if message.text == "what will be the weather in madagascar in two days" {
                onTextCaptured.fulfill()
            }
        }

        try! snips?.startSession(text: nil, intentFilter: nil, canBeEnqueued: false, sendIntentNotRecognized: false, customData: nil, siteId: nil)

        wait(for: [onTextCaptured], timeout: testTimeout)
    }
    
    func test_dialoge_configuration() {
        let intentName = "searchWeatherForecast"
        let onIntentReceived = expectation(description: "Intent recognized after reenabling it in the dialogue configuration")
        let onIntentNotRecognized = expectation(description: "Intent not recognized because it has been disabled")
        let enableIntent = DialogueConfigureMessage(intents: [DialogueConfigureIntent(intentId: intentName, enable: true)])
        let disableIntent = DialogueConfigureMessage(intents: [DialogueConfigureIntent(intentId: intentName, enable: false)])

        onSessionStartedHandler = { [weak self] message in
            DispatchQueue.main.sync {
                self?.playAudio(forResource: kWeatherAudioFile)
            }
        }

        onIntentDetected = { intent in
            if intent.intent.intentName == intentName {
                onIntentReceived.fulfill()
            }
        }

        onSessionEndedHandler = { [weak self] message in
            if message.sessionTermination.terminationType == .intentNotRecognized {
                onIntentNotRecognized.fulfill()
                try! self?.snips?.dialogueConfiguration(with: enableIntent)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    try! self?.snips?.startSession()
                }
            }
        }

        try! snips?.dialogueConfiguration(with: disableIntent)
        try! snips?.startSession()

        wait(for: [onIntentNotRecognized, onIntentReceived], timeout: testTimeout, enforceOrder: true)
    }
}

private extension SnipsPlatformTests {
   
    func stopSnipsPlatform() throws {
        snips = nil
        try removeSnipsUserDataIfNecessary()
    }
    
    func setupSnipsPlatform() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "assistant", withExtension: nil)!
        let g2pResources = Bundle(for: type(of: self)).url(forResource: "snips-g2p-resources/en", withExtension: nil)!
        
        snips = try SnipsPlatform(assistantURL: url,
                                  enableHtml: false,
                                  enableLogs: false,
                                  enableInjection: true,
                                  enableAsrPartialText: true,
                                  g2pResources: g2pResources,
                                  asrPartialTextPeriodMs: 1000,
                                  nluConfiguration: NluConfiguration(maxNumberOfIntentAlternatives: 3, maxNumberOfSlotAlternatives: 3))
        
        snips?.onIntentDetected = { [weak self] intent in
            self?.onIntentDetected?(intent)
        }
        snips?.onHotwordDetected = { [weak self] in
            self?.onHotwordDetected?()
        }
        snips?.onSessionStartedHandler = { [weak self] sessionStartedMessage in
            // Wait a bit to prevent timeout on slow machines. Probably due to race conditions in megazord.
            Thread.sleep(forTimeInterval: 2)
            self?.onSessionStartedHandler?(sessionStartedMessage)
        }
        snips?.onSessionQueuedHandler = { [weak self] sessionQueuedMessage in
            self?.onSessionQueuedHandler?(sessionQueuedMessage)
        }
        snips?.onSessionEndedHandler = { [weak self] sessionEndedMessage in
            self?.onSessionEndedHandler?(sessionEndedMessage)
        }
        snips?.onListeningStateChanged = { [weak self] state in
            self?.onListeningStateChanged?(state)
        }
        snips?.speechHandler = { [weak self] sayMessage in
            self?.speechHandler?(sayMessage)
        }
        snips?.onIntentNotRecognizedHandler = { [weak self] message in
            self?.onIntentNotRecognizedHandler?(message)
        }
        snips?.onTextCapturedHandler = { [weak self] text in
            self?.onTextCapturedHandler?(text)
        }
        snips?.onPartialTextCapturedHandler = { [weak self] text in
            self?.onPartialTextCapturedHandler?(text)
        }
        snips?.onInjectionComplete = { [weak self] message in
            self?.onInjectionCompleteHandler?(message)
        }
        snips?.onInjectionResetComplete = { [weak self] message in
            self?.onInjectionResetCompleteHandler?(message)
        }
        try snips?.start()
    }
    
    func playAudio(forResource resource: String?, withExtension ext: String? = "wav", completionHandler: (() -> ())? = nil) {
        let audioURL = Bundle(for: type(of: self)).url(forResource: resource, withExtension: ext)!

        let closure = { [weak self] in
            let audioFile = try! AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatInt16, interleaved: true)
            let soundBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: kFrameCapacity)!
            let silenceBuffer = [Int16](repeating: 0, count: Int(kFrameCapacity))

            for _ in 0..<100 {
                try! self?.snips?.appendBuffer(silenceBuffer)
            }
            while let _ = try? audioFile.read(into: soundBuffer, frameCount: kFrameCapacity) {
                try! self?.snips?.appendBuffer(soundBuffer)
            }
            for _ in 0..<100 {
                try! self?.snips?.appendBuffer(silenceBuffer)
            }
        }
        
        // TODO: Hack to send audio after few seconds to wait for the ASR to really listen.
        soundQueue.asyncAfter(deadline: .now() + 1, execute: closure)
    }
    
    func removeSnipsUserDataIfNecessary() throws {
        let manager = FileManager.default
        let snipsUserDocumentURL = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("snips")
        var isDirectory = ObjCBool(true)
        let exists = manager.fileExists(atPath: snipsUserDocumentURL.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            try manager.removeItem(at: snipsUserDocumentURL)
        }
    }
}
