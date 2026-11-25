//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI
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

  static func highlight(_ code: String, language: String, colors: HighlightColors) async throws -> AttributedString {
    let result = try await sharedHighlight.request(code, mode: .languageAliasIgnoreIllegal(language), colors: colors)
    return result.attributedText
  }

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

/// Highlights source on a light or dark editor background.
public func highlightSource(_ code: String, language: String, colorScheme: ColorScheme) async throws -> AttributedString {
  let colors = CodeBlockConfig.Theme.xcode.highlightColors(for: colorScheme)
  let styled = try await HighlightTaskManager.highlight(code, language: language, colors: colors)
  let rendered = String(styled.characters)
  // The HTML decoder trims leading and trailing whitespace. Restore it for file previews.
  guard let range = code.range(of: rendered, options: .literal),
        code[..<range.lowerBound].allSatisfy(\.isWhitespace),
        code[range.upperBound...].allSatisfy(\.isWhitespace) else {
    return AttributedString(code)
  }
  return AttributedString(String(code[..<range.lowerBound])) + styled + AttributedString(String(code[range.upperBound...]))
}
