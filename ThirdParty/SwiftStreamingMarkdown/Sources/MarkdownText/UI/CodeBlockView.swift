//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
import SwiftUI

struct CodeBlockView: View {

  @Environment(\.markdownConfig) private var config: MarkdownRenderConfig
  @Environment(\.colorScheme) private var colorScheme

  let language: String
  let code: String
  let onCodeCopied: (() -> Void)?

  @State var copied: Bool = false
  @State private var highlighted: (request: HighlightTaskManager.Request, text: AttributedString)?
  @StateObject private var taskManager: HighlightTaskManager = HighlightTaskManager()

  init(language: String, code: String, onCodeCopied: (() -> Void)? = nil) {
    self.language = language
    self.code = code
    self.onCodeCopied = onCodeCopied
  }

  private var highlightRequest: HighlightTaskManager.Request {
    .init(code: code, language: language, colors: config.codeBlockConfig.theme.highlightColors(for: colorScheme))
  }

  private var renderedCode: AttributedString {
    let request = highlightRequest
    guard let highlighted, highlighted.request.language == request.language,
          highlighted.request.colors == request.colors else {
      return AttributedString(code)
    }
    if highlighted.request.code == code { return highlighted.text }
    // Keep the previous colors while the highlighter catches up with an append.
    guard let prefix = code.range(of: highlighted.request.code, options: [.anchored, .literal]) else {
      return AttributedString(code)
    }
    return highlighted.text + AttributedString(String(code[prefix.upperBound...]))
  }

  private var backgroundColor: Color? {
    config.codeBlockConfig.backgroundColor
  }

  private var foregroundColor: Color {
    config.codeBlockConfig.foregroundColor ?? Color.Static.Stone.Stone350
  }

  private var copyButton: some View {
    let title = copied ? String.codeCopiedLabel : String.codeCopyLabel
    return Button {
      #if canImport(UIKit)
      UIPasteboard.general.string = code
      #elseif canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(code, forType: .string)
      #endif
      copied = true
      onCodeCopied?()
    } label: {
      Label {
        Text(title)
      } icon: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 14, weight: .medium))
      }
      .labelStyle(.iconOnly)
      .foregroundStyle(foregroundColor)
      .frame(width: 26, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
  }

  @ViewBuilder
  var codeblock: some View {
    ScrollView(.horizontal) {
      HStack {
        if #available(iOS 16.1, *) {  // Minimum version for HighlightSwift
          Text(renderedCode)
            .font(config.codeBlockConfig.codeTextFonts)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Text(code)
            .font(config.codeBlockConfig.codeTextFonts)
            .foregroundStyle(Color.Theme.Component.CodeBlock.Foreground.FunctionParameter)
            .transition(.opacity)
        }
      }

    }.transaction { transaction in
      // The horizontal scrollView resizing animation was causing the code block to animate
      // all janky.
      transaction.animation = nil
    }
    .padding(16)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "Code" : language)
          .font(config.codeBlockConfig.chromeTextFonts)
          .foregroundStyle(foregroundColor)
        Spacer()
        copyButton
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 4)
      Divider().accessibilityHidden(true)
      codeblock
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.automatic)
    }
    .background(backgroundColor ?? .clear, in: RoundedRectangle(cornerRadius: 12))
    .onChange(of: copied, perform: { isCopied in
      if isCopied {
        Task {
          try await Task.sleep(seconds: 3)
          copied = false
        }
      }
    })
    .task(id: highlightRequest) {
      await taskManager.enqueue(highlightRequest) { request, text in
        highlighted = (request, text)
      }
    }
  }
}

#if DEBUG

#Preview {
  return LazyVStack {
    Spacer()
    CodeBlockView(language: "Python", code: "import random\n\ndef generate_and_add_numbers(num_numbers):\n    # Generate a list of random numbers random_numbers\n    random_numbers = [random.randint(1, 100) for _ in range(num_numbers)]\n\n\n    # Add the numbers together\n    sum_of_numbers = sum(random_numbers)\n\n    return random_numbers, sum_of_numbers\n\n# Example: Generate 5 random numbers and add them together\nnum_numbers = 5\nrandom_numbers, sum_of_numbers = generate_and_add_numbers(num_numbers)\nprint(f\"Generated numbers: {random_numbers}\")\nprint(f\"Sum of numbers: {sum_of_numbers}\")")
    Spacer()
  }.padding(24)
}

#endif
