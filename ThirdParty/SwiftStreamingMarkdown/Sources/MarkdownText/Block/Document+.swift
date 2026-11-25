//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI

extension Markdown.Document {

  func convert(with config: MarkdownRenderConfig) -> [MarkdownRenderable] {
    var blocks: [MarkdownRenderable] = []
    for child in blockConvertibleChildren {
      let block = child.convert(attributeContainer: NSAttributeContainer(), config: config)
      // Consecutive prose shares a native selection and a stable text view as it grows.
      if case .paragraph(_, let next) = block, case .paragraph(_, let previous)? = blocks.last {
        previous.append(NSAttributedString(string: "\n\n", attributes: [.font: config.paragraphStyle.textFonts.normal]))
        previous.append(next)
      } else {
        blocks.append(block)
      }
    }
    return blocks
  }
}
