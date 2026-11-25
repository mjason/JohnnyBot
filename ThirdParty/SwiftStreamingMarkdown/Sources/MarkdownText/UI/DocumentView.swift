//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Equatable
import Markdown
import SwiftUI

/// A SwiftUI view that renders a pre-parsed `RenderableDocument`. Use this
/// view when you already have a parsed document (e.g. driven by a streaming
/// pipeline); use `MarkdownView` when you want the package to parse for you.
@Equatable
public struct DocumentView: View {
  @Environment(\.markdownSelectionEditor) private var selectionEditor
  @StateObject var controller: MarkdownController

  let renderableDocument: RenderableDocument
  let config: MarkdownRenderConfig

  /// Create a `DocumentView`.
  /// - Parameters:
  ///   - renderableDocument: The parsed Markdown document to render.
  ///   - config: Render configuration. Defaults to `.default`.
  ///   - listener: Optional listener that receives render and interaction events.
  public init(
    renderableDocument: RenderableDocument,
    config: MarkdownRenderConfig = .default,
    listener: MarkdownListener? = nil
  ) {
    self.renderableDocument = renderableDocument
    self.config = config
    self._controller = StateObject(wrappedValue: MarkdownController(listener: listener))
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      BlockView(renderables: renderableDocument.renderables)
      if selectionEditor == nil, config.textSelectionConfig.isEnabled, renderableDocument.renderables.count > 1 || renderableDocument.hasStructuredSelection {
        Button {
          controller.isTextSelectionRequested = true
        } label: {
          Label(String.selectMoreTextLabel, systemImage: "selection.pin.in.out")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
      }
    }
    .environment(\.markdownConfig, config)
    .environment(\.markdownController, controller)
    .task {
      await controller.onAppear(markdown: renderableDocument)
    }
    .onChange(of: renderableDocument, perform: { md in
      controller.onChange(markdown: md)
    })
    .onDisappear {
      Task {
        await controller.onDisappear()
      }
    }
    .sheet(isPresented: $controller.isTextSelectionRequested) {
      if let selectionEditor {
        selectionEditor(renderableDocument.plainText)
      } else {
        TextSelectionView(
          text: renderableDocument.plainText,
          backgroundColor: config.textSelectionConfig.backgroundColor ?? Color.Theme.Background.Page.Chat.Flat
        ) {
          controller.isTextSelectionRequested = false
        }
      }
    }
  }
}

extension EnvironmentValues {
  /// Optional host editor presented by the document-wide text selection action.
  @Entry public var markdownSelectionEditor: (@MainActor (String) -> AnyView)? = nil
  /// The render configuration applied to descendant Markdown views.
  @Entry public var markdownConfig: MarkdownRenderConfig = .default
  /// The shared controller used by descendant Markdown views to route
  /// table/context-menu events to the configured `MarkdownListener`.
  @Entry public var markdownController: MarkdownController?
}

#if DEBUG

let text = """
 I found some resources that can help you compare gyms in your neighborhood. Here's a brief overview:

1. **The Ultimate Gym Guide** provides a comprehensive database of gyms where you can compare amenities, locations with pools, saunas, childcare, and more.
2. **Best Gyms Near Me** on Yelp lists gyms with a variety of classes, equipment, and amenities, from budget-friendly options to high-end gyms with all the bells and whistles.

You can visit these sites to get detailed information on membership prices and amenities for each gym. Remember to consider what's most important for your fitness routine when making your decision!
"""

#Preview {
  return MarkdownView(text: text)
}

#endif
