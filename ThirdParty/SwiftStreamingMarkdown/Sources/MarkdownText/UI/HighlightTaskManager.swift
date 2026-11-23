//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift

actor HighlightTaskManager: ObservableObject {
  struct Request: Hashable, Sendable {
    let code: String
    let language: String
    let colors: HighlightColors
  }

  /// Shared Highlight instance to avoid creating multiple JSContext/HLJS instances.
  /// Each Highlight() creates its own JSContext and evaluates highlight.min.js (~600KB).
  /// When multiple CodeBlockViews render concurrently, N separate JSContexts cause
  /// JavaScriptCore OOM crashes (COPILOT-IOS-3F9C, 3F7Z, 3FSQ).
  private static let sharedHighlight = Highlight()

  private var pending: Request?
  private var isProcessing = false

  func enqueue(_ request: Request, completion: @escaping @MainActor (Request, AttributedString) -> Void) {
    pending = request

    if !isProcessing {
      isProcessing = true
      Task {
        await processQueue(completion: completion)
      }
    }
  }

  private func processQueue(completion: @escaping @MainActor (Request, AttributedString) -> Void) async {
    defer { isProcessing = false }

    while let request = pending {
      pending = nil
      guard !request.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let language = request.language.split(whereSeparator: \.isWhitespace).first?.lowercased()
      let mode = language.map(HighlightMode.languageAliasIgnoreIllegal) ?? .automatic
      if let result = try? await Self.sharedHighlight.request(request.code, mode: mode, colors: request.colors),
         pending == nil {
        await completion(request, result.attributedText)
      }
    }
  }
}
