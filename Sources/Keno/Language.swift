import Foundation

/// A lightweight description of a language, enough for a fast single-pass lexer.
struct Language {
    enum Mode { case code, markup, markdown }

    var name: String
    var mode: Mode = .code
    var keywords: Set<String> = []
    var builtins: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (String, String)?
    var quotes: String = "\"'"
    var multilineQuotes: [String] = []
    var caseInsensitive = false
    var capitalizedAreTypes = false
    var colonKeysAreProperties = false
    var atAttributes = false
    var hashDirectives = false
    var dollarVariables = false
    var identifierExtras: String = ""

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    static func forURL(_ url: URL?) -> Language? {
        guard let url else { return nil }
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "makefile", "gnumakefile": return shell
        case "dockerfile", "containerfile": return dockerfile
        case ".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile", ".env": return shell
        case "gemfile", "rakefile", "podfile", "fastfile": return ruby
        case "package.swift": return swift
        default: break
        }
        switch url.pathExtension.lowercased() {
        case "swift": return swift
        case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "metal", "glsl": return cFamily
        case "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx": return javascript
        case "py", "pyw", "pyi": return python
        case "rb", "rake", "gemspec": return ruby
        case "go": return go
        case "rs": return rust
        case "java", "kt", "kts", "scala", "groovy", "gradle", "dart": return java
        case "cs": return csharp
        case "php": return php
        case "sh", "bash", "zsh", "fish", "command", "mk": return shell
        case "json", "jsonc", "json5", "geojson", "webmanifest": return json
        case "yml", "yaml": return yaml
        case "toml", "ini", "cfg", "conf", "properties": return toml
        case "html", "htm", "xhtml", "xml", "svg", "plist", "vue", "svelte", "xib", "storyboard", "xsd", "xsl": return markup
        case "css", "scss", "sass", "less": return css
        case "md", "markdown", "mdx": return markdown
        case "sql": return sql
        case "lua": return lua
        default: return nil
        }
    }

    // MARK: Definitions

    static let swift = Language(
        name: "Swift",
        keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw throws switch where while as is try await async actor any some get set willSet didSet lazy weak unowned mutating nonmutating override final required convenience dynamic indirect optional nonisolated isolated consuming borrowing macro package"),
        builtins: words("true false nil self Self super Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat Bool String Character Array Dictionary Set Optional Result Void Never Any AnyObject Error Data URL Date"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"", multilineQuotes: ["\"\"\""],
        capitalizedAreTypes: true, atAttributes: true, hashDirectives: true)

    static let cFamily = Language(
        name: "C",
        keywords: words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool class namespace template typename public private protected virtual override final friend operator new delete this throw try catch using constexpr noexcept nullptr decltype explicit mutable static_cast dynamic_cast reinterpret_cast const_cast auto co_await co_return co_yield concept requires @interface @implementation @end @property @protocol @selector @synthesize @class @optional @required"),
        builtins: words("true false NULL nullptr YES NO nil self super size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t std string vector map"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"'",
        capitalizedAreTypes: true, atAttributes: true, hashDirectives: true)

    static let javascript = Language(
        name: "JavaScript",
        keywords: words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set from as type interface enum implements private protected public readonly declare namespace module abstract keyof infer is satisfies"),
        builtins: words("true false null undefined NaN Infinity console window document globalThis Promise Array Object String Number Boolean Map Set JSON Math Date RegExp Error Symbol any unknown never string number boolean void object bigint"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"'", multilineQuotes: ["`"],
        capitalizedAreTypes: true, atAttributes: true, identifierExtras: "$")

    static let python = Language(
        name: "Python",
        keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
        builtins: words("True False None self cls print len range str int float bool list dict set tuple object type isinstance super open enumerate zip map filter sorted any all min max sum abs Exception ValueError TypeError KeyError"),
        lineComments: ["#"], quotes: "\"'", multilineQuotes: ["\"\"\"", "'''"],
        capitalizedAreTypes: true, atAttributes: true)

    static let ruby = Language(
        name: "Ruby",
        keywords: words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return then undef unless until when while yield require require_relative include extend attr_reader attr_writer attr_accessor private protected public lambda proc raise"),
        builtins: words("true false nil self super puts p"),
        lineComments: ["#"], quotes: "\"'", capitalizedAreTypes: true, identifierExtras: "?!")

    static let go = Language(
        name: "Go",
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
        builtins: words("true false nil iota bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any append cap close copy delete len make new panic print println recover"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"'", multilineQuotes: ["`"])

    static let rust = Language(
        name: "Rust",
        keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while macro_rules"),
        builtins: words("true false self Self Some None Ok Err i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"",
        capitalizedAreTypes: true, hashDirectives: true)

    static let java = Language(
        name: "Java",
        keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var val fun object when is in out override open data sealed companion init lateinit suspend typealias internal record yield"),
        builtins: words("true false null boolean byte char double float int long short void String Int Long Double Float Boolean Unit Any List Map"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"'", multilineQuotes: ["\"\"\""],
        capitalizedAreTypes: true, atAttributes: true)

    static let csharp = Language(
        name: "C#",
        keywords: words("abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while async await var get set init record when where yield"),
        builtins: words("true false null bool byte char decimal double float int long object sbyte short string uint ulong ushort void dynamic"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"'",
        capitalizedAreTypes: true, hashDirectives: true)

    static let php = Language(
        name: "PHP",
        keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while yield"),
        builtins: words("true false null TRUE FALSE NULL self parent"),
        lineComments: ["//", "#"], blockComment: ("/*", "*/"), quotes: "\"'",
        capitalizedAreTypes: true, dollarVariables: true)

    static let shell = Language(
        name: "Shell",
        keywords: words("if then else elif fi for while until do done case esac function in return local export readonly declare unset shift source alias exit break continue select time"),
        builtins: words("true false echo cd pwd printf read test eval exec set trap"),
        lineComments: ["#"], quotes: "\"'", dollarVariables: true, identifierExtras: "-")

    static let dockerfile = Language(
        name: "Dockerfile",
        keywords: words("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"),
        lineComments: ["#"], quotes: "\"'", dollarVariables: true)

    static let json = Language(
        name: "JSON",
        builtins: words("true false null"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"",
        colonKeysAreProperties: true)

    static let yaml = Language(
        name: "YAML",
        builtins: words("true false null yes no on off True False Null"),
        lineComments: ["#"], quotes: "\"'",
        colonKeysAreProperties: true, identifierExtras: "-.")

    static let toml = Language(
        name: "TOML",
        builtins: words("true false"),
        lineComments: ["#", ";"], quotes: "\"'", multilineQuotes: ["\"\"\"", "'''"],
        colonKeysAreProperties: true, identifierExtras: "-.")

    static let css = Language(
        name: "CSS",
        keywords: words("important inherit initial unset none auto"),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: "\"'",
        colonKeysAreProperties: true, atAttributes: true, dollarVariables: true, identifierExtras: "-")

    static let sql = Language(
        name: "SQL",
        keywords: words("select from where and or not insert into values update set delete create table drop alter add column index view join inner left right outer full on as group by order having limit offset union all distinct case when then else end is null like in between exists primary key foreign references default constraint unique begin commit rollback transaction with returning asc desc cascade"),
        builtins: words("true false int integer bigint smallint text varchar char boolean date timestamp numeric decimal real serial count sum avg min max coalesce now"),
        lineComments: ["--"], blockComment: ("/*", "*/"), quotes: "'\"", caseInsensitive: true)

    static let lua = Language(
        name: "Lua",
        keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
        builtins: words("true false nil self print pairs ipairs require table string math"),
        lineComments: ["--"], blockComment: ("--[[", "]]"), quotes: "\"'")

    static let markup = Language(name: "HTML", mode: .markup, quotes: "\"'")
    static let markdown = Language(name: "Markdown", mode: .markdown)
}
