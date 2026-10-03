//
//  SharedStateSuite.swift
//  SottoTests
//
//  The test host is Sotto, so tests touching process-wide state (the key window,
//  the pasteboard, Transcription.shared, Dictation.shared, the input preference)
//  would race each other under Swift Testing's parallelism. Suites that do are
//  nested here, and `.serialized` on the parent runs them one at a time.
//

import Testing

@Suite(.serialized)
enum SharedState {}
