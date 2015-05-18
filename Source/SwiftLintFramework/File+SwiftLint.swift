//
//  File+SwiftLint.swift
//  SwiftLint
//
//  Created by JP Simard on 2015-05-16.
//  Copyright (c) 2015 Realm. All rights reserved.
//

import SourceKittenFramework
import SwiftXPC

typealias Line = (index: Int, content: String)

extension File {
    public func matchPattern(pattern: String, withSyntaxKinds syntaxKinds: [SyntaxKind] = []) ->
        [NSRange] {
        return flatMap(NSRegularExpression(pattern: pattern, options: nil, error: nil)) { regex in
            let range = NSRange(location: 0, length: count(self.contents.utf16))
            let syntax = SyntaxMap(file: self)
            let matches = regex.matchesInString(self.contents, options: nil, range: range)
            return map(matches as? [NSTextCheckingResult]) { matches in
                return compact(matches.map { match in
                    let tokensInRange = syntax.tokens.filter {
                        NSLocationInRange($0.offset, match.range)
                    }
                    let kindsInRange = compact(map(tokensInRange) {
                        SyntaxKind(rawValue: $0.type)
                        })
                    if kindsInRange.count != syntaxKinds.count {
                        return nil
                    }
                    for (index, kind) in enumerate(syntaxKinds) {
                        if kind != kindsInRange[index] {
                            return nil
                        }
                    }
                    return match.range
                })
            }
        } ?? []
    }

    func astViolationsInDictionary(dictionary: XPCDictionary) -> [StyleViolation] {
        return (dictionary["key.substructure"] as? XPCArray ?? []).flatMap {
            // swiftlint:disable_rule:force_cast (safe to force cast)
            let subDict = $0 as! XPCDictionary
            // swiftlint:enable_rule:force_cast
            var violations = self.astViolationsInDictionary(subDict)
            if let kindString = subDict["key.kind"] as? String,
                let kind = flatMap(kindString, { SwiftDeclarationKind(rawValue: $0) }) {
                    violations.extend(self.validateTypeName(kind, dict: subDict))
                    violations.extend(self.validateVariableName(kind, dict: subDict))
                    violations.extend(self.validateTypeBodyLength(kind, dict: subDict))
                    violations.extend(self.validateFunctionBodyLength(kind, dict: subDict))
                    violations.extend(self.validateNesting(kind, dict: subDict))
            }
            return violations
        }
    }

    func validateTypeBodyLength(kind: SwiftDeclarationKind, dict: XPCDictionary) ->
        [StyleViolation] {
        let typeKinds: [SwiftDeclarationKind] = [
            .Class,
            .Struct,
            .Enum
        ]
        if !contains(typeKinds, kind) {
            return []
        }
        var violations = [StyleViolation]()
        if let offset = flatMap(dict["key.offset"] as? Int64, { Int($0) }),
            let bodyOffset = flatMap(dict["key.bodyoffset"] as? Int64, { Int($0) }),
            let bodyLength = flatMap(dict["key.bodylength"] as? Int64, { Int($0) }) {
            let location = Location(file: self, offset: offset)
            let startLine = self.contents.lineAndCharacterForByteOffset(bodyOffset)
            let endLine = self.contents.lineAndCharacterForByteOffset(bodyOffset + bodyLength)
            if let startLine = startLine?.line, let endLine = endLine?.line
                where endLine - startLine > 200 {
                violations.append(StyleViolation(type: .Length,
                    location: location,
                    reason: "Type body should be span 200 lines or less: currently spans " +
                    "\(endLine - startLine) lines"))
            }
        }
        return violations
    }

    func validateFunctionBodyLength(kind: SwiftDeclarationKind, dict: XPCDictionary) ->
        [StyleViolation] {
        let functionKinds: [SwiftDeclarationKind] = [
            .FunctionAccessorAddress,
            .FunctionAccessorDidset,
            .FunctionAccessorGetter,
            .FunctionAccessorMutableaddress,
            .FunctionAccessorSetter,
            .FunctionAccessorWillset,
            .FunctionConstructor,
            .FunctionDestructor,
            .FunctionFree,
            .FunctionMethodClass,
            .FunctionMethodInstance,
            .FunctionMethodStatic,
            .FunctionOperator,
            .FunctionSubscript
        ]
        if !contains(functionKinds, kind) {
            return []
        }
        var violations = [StyleViolation]()
        if let offset = flatMap(dict["key.offset"] as? Int64, { Int($0) }),
            let bodyOffset = flatMap(dict["key.bodyoffset"] as? Int64, { Int($0) }),
            let bodyLength = flatMap(dict["key.bodylength"] as? Int64, { Int($0) }) {
                let location = Location(file: self, offset: offset)
                let startLine = self.contents.lineAndCharacterForByteOffset(bodyOffset)
                let endLine = self.contents.lineAndCharacterForByteOffset(bodyOffset + bodyLength)
                if let startLine = startLine?.line, let endLine = endLine?.line
                    where endLine - startLine > 40 {
                        violations.append(StyleViolation(type: .Length,
                            location: location,
                            reason: "Function body should be span 40 lines or less: currently spans " +
                            "\(endLine - startLine) lines"))
                }
        }
        return violations
    }

    func validateTypeName(kind: SwiftDeclarationKind, dict: XPCDictionary) -> [StyleViolation] {
        let typeKinds: [SwiftDeclarationKind] = [
            .Class,
            .Struct,
            .Typealias,
            .Enum,
            .Enumelement
        ]
        if !contains(typeKinds, kind) {
            return []
        }
        var violations = [StyleViolation]()
        if let name = dict["key.name"] as? String,
            let offset = flatMap(dict["key.offset"] as? Int64, { Int($0) }) {
            let location = Location(file: self, offset: offset)
            let nameCharacterSet = NSCharacterSet(charactersInString: name)
            if !NSCharacterSet.alphanumericCharacterSet().isSupersetOfSet(nameCharacterSet) {
                violations.append(StyleViolation(type: .NameFormat,
                    location: location,
                    reason: "Type name should only contain alphanumeric characters: '\(name)'"))
            } else if !name.substringToIndex(name.startIndex.successor()).isUppercase() {
                violations.append(StyleViolation(type: .NameFormat,
                    location: location,
                    reason: "Type name should start with an uppercase character: '\(name)'"))
            } else if count(name) < 3 || count(name) > 40 {
                violations.append(StyleViolation(type: .NameFormat,
                    location: location,
                    reason: "Type name should be between 3 and 40 characters in length: " +
                    "'\(name)'"))
            }
        }
        return violations
    }

    func validateVariableName(kind: SwiftDeclarationKind, dict: XPCDictionary) -> [StyleViolation] {
        let variableKinds: [SwiftDeclarationKind] = [
            .VarClass,
            .VarGlobal,
            .VarInstance,
            .VarLocal,
            .VarParameter,
            .VarStatic
        ]
        if !contains(variableKinds, kind) {
            return []
        }
        var violations = [StyleViolation]()
        if let name = dict["key.name"] as? String,
            let offset = flatMap(dict["key.offset"] as? Int64, { Int($0) }) {
            let location = Location(file: self, offset: offset)
            let nameCharacterSet = NSCharacterSet(charactersInString: name)
            if !NSCharacterSet.alphanumericCharacterSet().isSupersetOfSet(nameCharacterSet) {
                violations.append(StyleViolation(type: .NameFormat,
                    location: location,
                    reason: "Variable name should only contain alphanumeric characters: '\(name)'"))
            } else if name.substringToIndex(name.startIndex.successor()).isUppercase() {
                violations.append(StyleViolation(type: .NameFormat,
                    location: location,
                    reason: "Variable name should start with a lowercase character: '\(name)'"))
            } else if count(name) < 3 || count(name) > 40 {
                violations.append(StyleViolation(type: .NameFormat,
                    location: location,
                    reason: "Variable name should be between 3 and 40 characters in length: " +
                    "'\(name)'"))
            }
        }
        return violations
    }

    func validateNesting(kind: SwiftDeclarationKind, dict: XPCDictionary, level: Int = 0) -> [StyleViolation] {
        var violations = [StyleViolation]()
        let typeKinds: [SwiftDeclarationKind] = [
            .Class,
            .Struct,
            .Typealias,
            .Enum,
            .Enumelement
        ]
        if let offset = flatMap(dict["key.offset"] as? Int64, { Int($0) }) {
            if level > 1 && contains(typeKinds, kind) {
                violations.append(StyleViolation(type: .Nesting,
                    location: Location(file: self, offset: offset),
                    reason: "Types should be nested at most 1 level deep"))
            } else if level > 5 {
                violations.append(StyleViolation(type: .Nesting,
                    location: Location(file: self, offset: offset),
                    reason: "Statements should be nested at most 5 levels deep"))
            }
        }
        violations.extend(compact((dict["key.substructure"] as? XPCArray ?? []).map { subItem in
            let subDict = subItem as? XPCDictionary
            let kindString = subDict?["key.kind"] as? String
            let kind = flatMap(kindString) { kindString in
                return SwiftDeclarationKind(rawValue: kindString)
            }
            if let kind = kind, subDict = subDict {
                return (kind, subDict)
            }
            return nil
        } as [(SwiftDeclarationKind, XPCDictionary)?]).flatMap { (kind, dict) in
            self.validateNesting(kind, dict: dict, level: level + 1)
        })
        return violations
    }

    internal var stringViolations: [StyleViolation] {
        let lines = contents.lines()
        // FIXME: Using '+' to concatenate these arrays would be nicer,
        //        but slows the compiler to a crawl.
        var violations = LineLengthRule.validateFile(self)
        violations.extend(LeadingWhitespaceRule.validateFile(self))
        violations.extend(TrailingWhitespaceRule.validateFile(self))
        violations.extend(TrailingNewlineRule.validateFile(self))
        violations.extend(ForceCastRule.validateFile(self))
        violations.extend(FileLengthRule.validateFile(self))
        violations.extend(TodoRule.validateFile(self))
        violations.extend(ColonRule.validateFile(self))
        return violations
    }
}