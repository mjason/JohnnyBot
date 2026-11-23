//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI
import UniformTypeIdentifiers

extension Markdown.Text: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: string).mergingAttributes(attributeContainer)
    if attributeContainer[.link] == nil { InlineReferences.apply(to: result, config: config) }
    return result
  }
}

extension Markdown.Emphasis: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    let str = NSMutableAttributedString()
    var newContainer = attributeContainer

    if let currentTextFonts = attributeContainer[.typography] as? TextFonts {
      let currentFont = attributeContainer[.font] as? MDFont
      newContainer[.font] = currentFont.map { currentTextFonts.italicize(font: $0) } ?? currentTextFonts.italic
    } else {
      newContainer[.font] = config.paragraphStyle.textFonts.italic ?? config.paragraphStyle.textFonts.normal
    }
    self.inlineConvertibleChildren.forEach { convertible in
      str.append(convertible.convert(attributeContainer: newContainer, config: config))
    }
    return str
  }
}

extension Markdown.Strong: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    let str = NSMutableAttributedString()
    var newContainer = attributeContainer
    if let currentTextFonts = attributeContainer[.typography] as? TextFonts {
      let currentFont = attributeContainer[.font] as? MDFont
      newContainer[.font] = currentFont.map { currentTextFonts.bold(font: $0) } ?? currentTextFonts.bold
    } else {
      newContainer[.font] = config.paragraphStyle.textFonts.bold ?? config.paragraphStyle.textFonts.normal
    }
    if self.parent is Paragraph && self.indexInParent == 0 && self.parent?.parent is ListItem && parent?.indexInParent == 0 {
      newContainer[.foregroundColor] = MDColor(config.inlineStyle.boldTextColor)
    }
    self.inlineConvertibleChildren.forEach { convertible in
      str.append(convertible.convert(attributeContainer: newContainer, config: config))
    }
    return str
  }
}

extension Markdown.Strikethrough: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    let str = NSMutableAttributedString()
    var container = attributeContainer
    container[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    container[.strikethroughColor] = container[.foregroundColor]
    self.inlineConvertibleChildren.forEach { convertible in
      str.append(convertible.convert(attributeContainer: container, config: config))
    }
    return str
  }
}

extension Markdown.Link: InlineConvertible {
  /// True when this link is a citation that should render as an attachment
  /// bubble. Delegates to the supplied `CitationCoder` so the marker /
  /// query-param format is configurable per render.
  func isInlineCitation(coder: CitationCoder) -> Bool {
    guard let destination = self.destination,
          let url = self.createURL(from: destination)
    else {
      return false
    }
    return coder.isCitation(linkText: self.plainText, url: url)
  }

  private func createURL(from string: String) -> URL? {
    return URL.fromMixedEncodingString(string)
  }

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    var container = attributeContainer

    func buildAttributedString() -> NSMutableAttributedString {
      let str = NSMutableAttributedString()
      self.inlineConvertibleChildren.forEach { convertible in
        str.append(convertible.convert(attributeContainer: container, config: config))
      }
      return str
    }

    guard let destination = self.destination,
          let url = self.createURL(from: destination)
    else {
      // Not a valid URL, return plain text
      return buildAttributedString()
    }

    let coder = config.citationConfig.coder
    if config.citationConfig.isEnabled, self.isInlineCitation(coder: coder) {
      // Extract title from URL query parameters for new attachment citation format
      if let attachmentData = coder.decode(linkDestination: destination),
         let citationAttachment = InlineCitationAttachment(citationData: attachmentData, citationConfig: config.citationConfig) {

        // Create attributed string with the citation attachment
        let attributedString = NSMutableAttributedString()
        attributedString.append(NSAttributedString(attachment: citationAttachment))

        return attributedString
      }
      // Fallback to empty string if we can't extract the title
      return NSMutableAttributedString(string: "")
    } else {
      // Is a real link, provided as markdown
      container[.link] = url
      container[.font] = config.inlineStyle.linkTextFont
      container[.foregroundColor] = MDColor(config.inlineStyle.linkTextColor)
      container[.underlineStyle] = config.inlineStyle.linkUnderlineStyle.rawValue
      return buildAttributedString()
    }
  }
}

extension Markdown.SoftBreak: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    return NSMutableAttributedString(string: "\n").mergingAttributes(attributeContainer)
  }
}

extension Markdown.LineBreak: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    return NSMutableAttributedString(string: "\n").mergingAttributes(attributeContainer)
  }
}

extension Markdown.InlineCode: InlineConvertible {

  var isInlineLatex: Bool {
    return self.code.hasPrefix(LaTexPreProcessorImpl.inlineCodePrefix) && self.code.hasSuffix(LaTexPreProcessorImpl.inlineCodeSuffix)
  }

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    var codeContent = self.code
    if self.isInlineLatex {
      codeContent = String(self
        .code
        .dropFirst(LaTexPreProcessorImpl.inlineCodePrefix.count)
        .dropLast(LaTexPreProcessorImpl.inlineCodeSuffix.count))
      let font = attributeContainer[NSAttributedString.Key.font] as? MDFont ?? config.paragraphStyle.textFonts.normal
      let textColor = MDColor(config.paragraphStyle.textColor)
      #if canImport(UIKit)
      let lightHex = textColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).toHexString()
      let darkHex = textColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).toHexString()
      #elseif canImport(AppKit)
      let lightHex = textColor.resolvedForAppearance(.aqua).toHexString()
      let darkHex = textColor.resolvedForAppearance(.darkAqua).toHexString()
      #endif
      let attachmentData = LatexAttachmentData(
        latex: codeContent,
        fontSize: font.pointSize,
        lightTextColor: lightHex,
        darkTextColor: darkHex
      )
      let encoder = JSONEncoder()
      if let payload = try? encoder.encode(attachmentData) {
        let attachment = NSTextAttachment(data: payload, ofType: UTType.data.identifier)
        return NSMutableAttributedString(attachment: attachment)
      }
    }
    var container = attributeContainer
    container[.font] = config.inlineStyle.codeTextFont
    container[.foregroundColor] = MDColor(config.inlineStyle.codeTextColor)
    container[.backgroundColor] = MDColor(config.inlineStyle.codeBackgroundColor)
    container[.underlineStyle] =  NSUnderlineStyle.patternDot.rawValue
    container[.underlineColor] = MDColor(config.inlineStyle.codeUnderlineColor)
    let result = NSMutableAttributedString(string: codeContent).mergingAttributes(container)
    if container[.link] == nil { InlineReferences.apply(to: result, config: config, isCode: true) }
    return result
  }
}

extension Markdown.Table.Cell: InlineConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    let str = NSMutableAttributedString()
    self.inlineConvertibleChildren.forEach { convertible in
      str.append(convertible.convert(attributeContainer: attributeContainer, config: config))
    }
    return str
  }
}

private enum InlineReferences {
  // Only match inline prose. Fenced code blocks retain their original formatting.
  static let pattern = try! NSRegularExpression(pattern:
    #"(?<![\w:/])(?:https?://[^\s<>"，。；！？]+|(?:(?:file://)?/|\.\.?/|[\w.-]+/)(?:[\w.@%+~-]+/)*[\w@%+~-]+(?:\.[\w-]+)+(?:[:#]L?\d+)?|[\w-]+\.(?:swift|ts|tsx|js|jsx|py|rs|go|md|json|ya?ml|toml|sh|cpp|h|css|html)(?:[:#]L?\d+)?)"#,
    options: [.caseInsensitive])

  static let codePath = try! NSRegularExpression(pattern:
    #"^(?:(?:(?:file://)?/|\.\.?/|[\w.-]+/)[\w .@%+~/#:-]*[\w~]|Dockerfile|Makefile|\.[\w-]+)$"#)

  static func apply(to text: NSMutableAttributedString, config: MarkdownRenderConfig, isCode: Bool = false) {
    let source = text.string as NSString
    let full = NSRange(location: 0, length: source.length)
    let ranges = isCode && codePath.firstMatch(in: text.string, range: full) != nil
      ? [full] : pattern.matches(in: text.string, range: full).map(\.range)
    for var range in ranges {
      var raw = source.substring(with: range)
      while let last = raw.last, ".,;!?)]".contains(last) {
        if last == ")" && raw.filter({ $0 == "(" }).count >= raw.filter({ $0 == ")" }).count { break }
        raw.removeLast()
        range.length -= 1
      }
      guard let url = URL.fromMixedEncodingString(raw) else { continue }
      text.addAttributes([.link: url, .foregroundColor: MDColor(config.inlineStyle.linkTextColor),
                          .underlineStyle: config.inlineStyle.linkUnderlineStyle.rawValue], range: range)
    }
  }
}
