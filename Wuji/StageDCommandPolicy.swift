import Foundation

enum StageDEnvironmentLock {
    static let rootFSURL = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz"
    static let rootFSSize = 3_851_686
    static let rootFSSHA256 = "f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"
    static let repositories = [
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/main",
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/community"
    ]
    static let packages = ["git", "python3", "nodejs", "npm"]
    static let cloneURL = "https://github.com/Da-AiXZ/Wuji.git"
    static let cloneTarget = "Wuji-StageC"
    static let acceptedStageCCommit = "d8544f431b25fb33c9541e7b2b2405ccb4d686ce"
}

enum StageDCommandParser {
    private static let grammarScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:=+,-"
    )
    private static let quoteScalars = CharacterSet(charactersIn: "'\"")
    private static let shellMetaScalars = CharacterSet(charactersIn: "|&;<>()$`\\!{}[]*?~#")
    private static let knownExecutables: Set<String> = [
        "pwd", "ls", "cat", "sed", "rm", "cp", "mv", "git", "python3", "node", "npm", "apk",
        "swift", "go", "rustc", "ruby", "pip", "pip3", "cargo"
    ]

    static func parse(
        command: String,
        cwd: String,
        limits: StageDLimits = .production
    ) throws -> StageDParsedCommand {
        guard !command.isEmpty else { throw StageDCommandError.emptyCommand }
        guard command.utf8.count <= limits.maximumCommandBytes else {
            throw StageDCommandError.commandLimit
        }
        guard !command.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0.value == 0x7f
        }) else { throw StageDCommandError.controlCharacter }
        guard !command.unicodeScalars.contains(where: { quoteScalars.contains($0) }) else {
            throw StageDCommandError.ambiguousQuoting
        }
        guard !command.unicodeScalars.contains(where: { shellMetaScalars.contains($0) }) else {
            throw StageDCommandError.shellMetacharacter
        }
        guard !command.hasPrefix(" "), !command.hasSuffix(" "), !command.contains("  ") else {
            throw StageDCommandError.ambiguousWhitespace
        }
        let tokens = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let executable = tokens.first, !executable.isEmpty else {
            throw StageDCommandError.emptyCommand
        }
        let arguments = Array(tokens.dropFirst())
        guard arguments.count <= limits.maximumArgumentCount,
              tokens.allSatisfy({ !$0.isEmpty && $0.utf8.count <= limits.maximumArgumentBytes }) else {
            throw StageDCommandError.argumentLimit
        }
        guard tokens.allSatisfy({ token in
            token.unicodeScalars.allSatisfy { grammarScalars.contains($0) }
        }) else { throw StageDCommandError.shellMetacharacter }
        guard knownExecutables.contains(executable) else {
            throw StageDCommandError.unsupportedExecutable
        }
        let normalizedCWD = try normalizeRelativePath(cwd, limits: limits, allowEmpty: true)
        return StageDParsedCommand(
            original: command,
            executable: executable,
            arguments: arguments,
            cwd: normalizedCWD
        )
    }

    static func normalizeRelativePath(
        _ value: String,
        limits: StageDLimits = .production,
        allowEmpty: Bool
    ) throws -> String {
        if value == "." { return "" }
        guard value.utf8.count <= limits.maximumCWDBytes,
              !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw StageDCommandError.boundaryCrossing
        }
        if value.isEmpty {
            guard allowEmpty else { throw StageDCommandError.invalidCWD }
            return ""
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StageDCommandError.boundaryCrossing
        }
        return value
    }
}

enum StageDPolicyDecision: Equatable, Sendable {
    case authorized(StageDAuthorizedCommand)
    case rejected(StageDCommandRisk, StageDCommandError)
    case unavailable(String)
}

struct StageDCommandPolicy: Sendable {
    let workspaceIdentitySHA256: String
    let write: StageDBoundedWrite?
    let limits: StageDLimits

    init(
        workspaceIdentitySHA256: String,
        write: StageDBoundedWrite?,
        limits: StageDLimits = .production
    ) {
        self.workspaceIdentitySHA256 = workspaceIdentitySHA256
        self.write = write
        self.limits = limits
    }

    func decide(command: String, cwd: String) -> StageDPolicyDecision {
        let parsed: StageDParsedCommand
        do { parsed = try StageDCommandParser.parse(command: command, cwd: cwd, limits: limits) }
        catch let error as StageDCommandError {
            let risk: StageDCommandRisk = error == .boundaryCrossing ? .boundaryCrossing : .unsupported
            return .rejected(risk, error)
        } catch {
            return .rejected(.unsupported, .unsupportedArguments)
        }

        let classification = classify(parsed)
        switch classification {
        case let .unavailable(name):
            return .unavailable(name)
        case let .rejected(risk, error):
            return .rejected(risk, error)
        case let .authorized(risk, root, boundWrite, cloneTarget):
            return .authorized(.init(
                parsed: parsed,
                risk: risk,
                executionRoot: root,
                workspaceIdentitySHA256: workspaceIdentitySHA256,
                write: boundWrite,
                cloneTarget: cloneTarget
            ))
        }
    }

    private enum Classification {
        case authorized(StageDCommandRisk, StageDExecutionRoot, StageDBoundedWrite?, String?)
        case rejected(StageDCommandRisk, StageDCommandError)
        case unavailable(String)
    }

    private func classify(_ parsed: StageDParsedCommand) -> Classification {
        let arguments = parsed.arguments
        switch parsed.executable {
        case "swift", "go", "rustc", "ruby", "pip", "pip3", "cargo":
            return .unavailable(parsed.executable)
        case "pwd":
            return arguments.isEmpty
                ? .authorized(.safeReadOnly, .workspace, nil, nil)
                : .rejected(.unsupported, .unsupportedArguments)
        case "ls":
            guard arguments.isEmpty
                    || arguments == ["-1A"]
                    || (arguments.count == 2 && arguments[0] == "--" && safePath(arguments[1], allowEmpty: true))
                    || (arguments.count == 3 && arguments[0] == "-1A" && arguments[1] == "--" && safePath(arguments[2], allowEmpty: true)) else {
                return pathAwareRejection(arguments)
            }
            return .authorized(.safeReadOnly, .workspace, nil, nil)
        case "cat":
            guard arguments.count == 2, arguments[0] == "--", safePath(arguments[1], allowEmpty: false) else {
                return pathAwareRejection(arguments)
            }
            return .authorized(.safeReadOnly, .workspace, nil, nil)
        case "git":
            if arguments == ["--version"] || arguments == ["rev-parse", "HEAD"]
                || arguments == ["remote", "get-url", "origin"] {
                return .authorized(.safeReadOnly, .workspace, nil, nil)
            }
            let clone = [
                "clone", "--depth", "8", "--no-tags", "--single-branch",
                StageDEnvironmentLock.cloneURL, StageDEnvironmentLock.cloneTarget
            ]
            if arguments == clone && parsed.cwd.isEmpty {
                return .authorized(.network, .cloneRoot, nil, StageDEnvironmentLock.cloneTarget)
            }
            if arguments.contains(where: { boundaryPath($0) }) {
                return .rejected(.boundaryCrossing, .boundaryCrossing)
            }
            return .rejected(.unsupported, .invalidClone)
        case "python3":
            guard arguments == ["--version"] || arguments == ["-V"] || arguments == ["-c", "pass"] else {
                return .rejected(.unsupported, .unsupportedArguments)
            }
            return .authorized(.safeReadOnly, .workspace, nil, nil)
        case "node":
            guard arguments == ["--version"] || arguments == ["-e", "0"] else {
                return .rejected(.unsupported, .unsupportedArguments)
            }
            return .authorized(.safeReadOnly, .workspace, nil, nil)
        case "npm":
            guard arguments == ["--version"] else {
                return .rejected(.unsupported, .unsupportedArguments)
            }
            return .authorized(.safeReadOnly, .workspace, nil, nil)
        case "apk":
            if arguments == ["add"] + StageDEnvironmentLock.packages {
                return .authorized(.installation, .rootfs, nil, nil)
            }
            if arguments == ["policy"] + StageDEnvironmentLock.packages {
                return .authorized(.safeReadOnly, .rootfs, nil, nil)
            }
            return .rejected(.unsupported, .invalidInstall)
        case "sed":
            guard let write,
                  parsed.cwd.isEmpty,
                  arguments == ["-i", write.sedExpression, write.relativePath],
                  safePath(write.relativePath, allowEmpty: false) else {
                return .rejected(.workspaceWrite, .writeNotBound)
            }
            return .authorized(.workspaceWrite, .workspace, write, nil)
        case "rm":
            return .rejected(.delete, .destructiveRejected)
        case "cp", "mv":
            return .rejected(.overwrite, .destructiveRejected)
        default:
            return .rejected(.unsupported, .unsupportedExecutable)
        }
    }

    private func pathAwareRejection(_ arguments: [String]) -> Classification {
        arguments.contains(where: boundaryPath)
            ? .rejected(.boundaryCrossing, .boundaryCrossing)
            : .rejected(.unsupported, .unsupportedArguments)
    }

    private func safePath(_ value: String, allowEmpty: Bool) -> Bool {
        (try? StageDCommandParser.normalizeRelativePath(value, limits: limits, allowEmpty: allowEmpty)) != nil
    }

    private func boundaryPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("\\") || value.contains("\\")
            || value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
