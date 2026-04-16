import Foundation

struct SourceLocation: Sendable, CustomStringConvertible {
    let line: Int
    let column: Int
    let file: String?

    init(line: Int, column: Int, file: String? = nil) {
        self.line = line
        self.column = column
        self.file = file
    }

    var description: String {
        if let file {
            return "\(file):line \(line), column \(column)"
        }
        return "line \(line), column \(column)"
    }
}

enum TokenKind: Sendable, Equatable {
    case importKeyword          // import
    case letKeyword             // let
    case varKeyword             // var
    case ifKeyword              // if
    case elseKeyword            // else
    case repeatKeyword          // repeat
    case forKeyword             // for
    case inKeyword              // in
    case menuKeyword            // menu
    case caseKeyword            // case
    case funcKeyword            // func
    case returnKeyword          // return
    case containsKeyword        // contains

    case identifier(String)     // action names, variable names
    case stringLiteral(String)  // "hello"
    case numberLiteral(Double)  // 42, 3.14
    case boolLiteral(Bool)      // true, false

    case leftParen              // (
    case rightParen             // )
    case leftBrace              // {
    case rightBrace             // }
    case leftBracket            // [
    case rightBracket           // ]
    case comma                  // ,
    case colon                  // :
    case arrow                  // ->
    case equals                 // =
    case doubleEquals           // ==
    case notEquals              // !=
    case greaterThan            // >
    case lessThan               // <
    case hash                   // #
    case dot                    // .
    case newline                // \n (significant for statement separation)

    case comment(String)        // // comment text
    case eof
}

struct Token: Sendable {
    let kind: TokenKind
    let location: SourceLocation
}
