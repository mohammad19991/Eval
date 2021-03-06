import Foundation

class Eval {
    static func main() {
        print("💁🏻‍♂️ Job type: \(TravisCI.jobType().description)")
        
        if isSpecificJob() {
            return
        }
        
        if TravisCI.isPullRquestJob() || Shell.nextArg("--env") == "pr" {
            runPullRequestLane()
        } else {
            runContinousIntegrationLane()
        }
    }
    
    static func runPullRequestLane() {
        runCommands("Building Pull Request") {
            try prepareForBuild()
            try prepareExamplesForBuild()
            
            try build()
            try buildExamples()
            
            try runTests()
            try runTestsOnExamples()
            
            try runLinter()
            
            try runDanger()
        }
    }

    static func runContinousIntegrationLane() {
        runCommands("Building CI") {
            try prepareForBuild()
            try prepareExamplesForBuild()
            
            try build()
            try buildExamples()
            
            try runTests()
            try runTestsOnExamples()
            
            try runLinter()
            
            try generateDocs()
            try publishDocs()
            
            try runCocoaPodsLinter()
            
            try testCoverage()
            
            try runDanger()
        }
    }
    
    static func isSpecificJob() -> Bool {
        guard let jobsString = Shell.nextArg("--jobs") else { return false }
        let jobsToRun = jobsString.split(separator: ",").map({ String($0) })
        let jobsFound = jobsToRun.flatMap { job in jobs.first { $0.key == job } }
        runCommands("Executing jobs: \(jobsString)") {
            if let job = jobsToRun.first(where: { !self.jobs.keys.contains($0) }) {
                throw CIError.logicalError(message: "Job not found: \(job)")
            }
            try jobsFound.forEach {
                print("🏃🏻 Running job \($0.key)")
                try $0.value()
            }
        }
        return !jobsFound.isEmpty
    }
    
    static func runCommands(_ title: String, commands: () throws -> Void) {
        do {
            if !TravisCI.isRunningLocally() {
                print("travis_fold:start: \(title)")
            }
            
            print("ℹ️ \(title)")
            try commands()
            
            if !TravisCI.isRunningLocally() {
                print("travis_fold:end: \(title)")
            }
            
            print("🎉 Finished successfully")
        } catch let CIError.invalidExitCode(statusCode, errorOutput) {
            print("😢 Error happened: [InsufficientExitCode] ", errorOutput ?? "unknown error")
            exit(statusCode)
        } catch let CIError.logicalError(message) {
            print("😢 Error happened: [LogicalError] ", message)
            exit(-1)
        } catch CIError.timeout {
            print("🕙 Timeout")
            exit(-1)
        } catch {
            print("😢 Error happened [General]")
            exit(-1)
        }
    }

    // MARK: Tasks
    
    static let jobs = [
        "prepareForBuild": prepareForBuild,
        "prepareExamplesForBuild": prepareExamplesForBuild,
        "build": build,
        "buildExamples": buildExamples,
        "runTests": runTests,
        "runTestsOnExamples": runTestsOnExamples,
        "runLinter": runLinter,
        "generateDocs": generateDocs,
        "publishDocs": publishDocs,
        "runCocoaPodsLinter": runCocoaPodsLinter,
        "testCoverage": testCoverage,
        "runDanger": runDanger,
    ]

    static func prepareForBuild() throws {
        if TravisCI.isRunningLocally() {
            print("🔦 Install dependencies")
            try Shell.executeAndPrint("rm -f Package.resolved")
            try Shell.executeAndPrint("rm -rf .build")
            try Shell.executeAndPrint("rm -rf build")
            try Shell.executeAndPrint("rm -rf Eval.xcodeproj")
            try Shell.executeAndPrint("bundle install")
        }
        
        print("🤖 Generating project file")
        try Shell.executeAndPrint("swift package generate-xcodeproj")
    }

    static func build() throws {
        print("♻️ Building")
        try Shell.executeAndPrint("swift build", timeout: 60)
        try Shell.executeAndPrint("xcodebuild clean build -configuration Release -scheme Eval-Package | bundle exec xcpretty --color", timeout: 60)
    }

    static func runTests() throws {
        print("👀 Running automated tests")
        try Shell.executeAndPrint("swift test", timeout: 60)
        try Shell.executeAndPrint("xcodebuild test -configuration Release -scheme Eval-Package -enableCodeCoverage YES | bundle exec xcpretty --color", timeout: 60)
    }
    
    static func runLinter() throws {
        print("👀 Running linter")
        try Shell.executeAndPrint("swiftlint lint", timeout: 10)
    }

    static func generateDocs() throws {
        print("📚 Generating documentation")
        try Shell.executeAndPrint("bundle exec jazzy --config .jazzy.yml", timeout: 60)
    }

    static func publishDocs() throws {
        print("📦 Publishing documentation")
        
        let dir = "gh-pages"
        let file = "github_rsa"
        defer {
            print("📦 ✨ Cleaning up")
            try! Shell.executeAndPrint("rm -f \(file)")
            try! Shell.executeAndPrint("rm -rf \(dir)")
            try! Shell.executeAndPrint("rm -rf Documentation/Output")
        }
        
        if TravisCI.isRunningLocally() {
            print("📦 ✨ Preparing")
            try! Shell.executeAndPrint("rm -rf \(dir)")
        }

        if let repo = currentRepositoryUrl()?.replacingOccurrences(of: "https://github.com/", with: "git@github.com:") {
            let branch = "gh-pages"

            print("📦 📥 Fetching previous docs")
            try Shell.executeAndPrint("git clone --depth 1 -b \(branch) \(repo) \(dir)", timeout: 30)

            print("📦 📄 Updating to the new one")
            try Shell.executeAndPrint("cp -Rf Documentation/Output/ \(dir)")

            print("📦 👉 Committing")
            try Shell.executeAndPrint("git -C \(dir) add .")
            try Shell.executeAndPrint("git -C \(dir) commit -m 'Automatic documentation update'")
            try Shell.executeAndPrint("git -C \(dir) add .")

            print("📦 📤 Pushing")
            let remote = "origin"
            try Shell.executeAndPrint("git -C \(dir) push \(remote) \(branch)", timeout: 30)
        } else {
            throw CIError.logicalError(message: "Repository URL not found")
        }
    }
    
    static func runCocoaPodsLinter() throws {
        print("🔮 Validating CocoaPods support")
        let flags = TravisCI.isRunningLocally() ? "--verbose" : ""
        try Shell.executeAndPrint("bundle exec pod lib lint \(flags)", timeout: 300)
    }
    
    static func testCoverage() throws {
        defer {
            print("📦 ✨ Cleaning up")
            try! Shell.executeAndPrint("rm -f Eval.framework.coverage.txt")
            try! Shell.executeAndPrint("rm -f EvalTests.xctest.coverage.txt")
        }
        
        print("☝🏻 Uploading code test coverage data")
        try Shell.executeAndPrint("bash <(curl -s https://codecov.io/bash) -J Eval", timeout: 120)
    }
    
    static func runDanger() throws {
        if TravisCI.isRunningLocally() {
            print("⚠️ Running Danger in local mode")
            try Shell.executeAndPrint("bundle exec danger local || true")
        } else if TravisCI.isPullRquestJob() {
            print("⚠️ Running Danger")
            try Shell.executeAndPrint("bundle exec danger || true")
        }
    }
    
    static func prepareExamplesForBuild() throws {
        print("🤖 Generating project file on Examples")
        try onAllExamples { example in
            let cleanup = [
                "rm -f Package.resolved",
                "rm -rf .build",
                "rm -rf build",
                "rm -rf \(example).xcodeproj"
            ]
            let generate = [
                "swift package generate-xcodeproj"
            ]
            return (cleanup + generate).joined(separator: ";")
        }
    }
    
    static func buildExamples() throws {
        print("♻️ Building Examples")
        try onAllExamples { example in
            return "xcodebuild clean build -scheme \(example)-Package | bundle exec xcpretty --color"
        }
    }

    static func runTestsOnExamples() throws {
        print("👀 Running automated tests on Examples")
        try onAllExamples { example in
            return "xcodebuild test -scheme \(example)-Package | bundle exec xcpretty --color"
        }
    }
    
    // MARK: Helpers
    
    static func onAllExamples(_ command: (String) throws -> String) throws {
        for (name, directory) in try examples() {
            let commands = [
                "pushd \(directory)",
                try command(name),
                "popd"
            ]
            try Shell.executeAndPrint(commands.joined(separator: ";"), timeout: 60)
        }
    }
    
    static func examples() throws -> [(name: String, directory: String)] {
        let directory = "Examples"
        return try FileManager.default.contentsOfDirectory(atPath: directory).map { ($0, "\(directory)/\($0)") }
    }

    static func currentRepositoryUrl(dir: String = ".") -> String? {
        if let command = try? Shell.execute("git -C \(dir) config --get remote.origin.url"),
            let output = command?.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            return output
        }
        return nil
    }

    static func currentBranch(dir: String = ".") -> String? {
        if let command = try? Shell.execute("git -C \(dir) rev-parse --abbrev-ref HEAD"),
            let output = command?.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            return output
        }
        return nil
    }
}

class TravisCI {
    enum JobType : CustomStringConvertible {
        case local
        case travisAPI
        case travisCron
        case travisPushOnBranch(branch: String)
        case travisPushOnTag(name: String)
        case travisPullRequest(branch: String, sha: String, slug: String)
        
        var description: String {
            switch self {
                case .local: return "Local"
                case .travisAPI: return "Travis (API)"
                case .travisCron: return "Travis (Cron job)"
                case .travisPushOnBranch(let branch): return "Travis (Push on branch '\(branch)')"
                case .travisPushOnTag(let name): return "Travis (Push of tag '\(name)')"
                case .travisPullRequest(let branch): return "Travis (Pull Request on branch '\(branch)')"
            }
        }
    }
    
    static func isPullRquestJob() -> Bool {
        return Shell.env(name: "TRAVIS_EVENT_TYPE") == "pull_request"
    }
    
    static func isRunningLocally() -> Bool {
        return Shell.env(name: "TRAVIS") != "true"
    }
    
    static func isCIJob() -> Bool {
        return !isRunningLocally() && !isPullRquestJob()
    }
    
    static func jobType() -> JobType {
        if isRunningLocally() {
            return .local
        } else if isPullRquestJob() {
            return .travisPullRequest(branch: Shell.env(name: "TRAVIS_PULL_REQUEST_BRANCH") ?? "",
                                      sha: Shell.env(name: "TRAVIS_PULL_REQUEST_SHA") ?? "",
                                      slug: Shell.env(name: "TRAVIS_PULL_REQUEST_SLUG") ?? "")
        } else if Shell.env(name: "TRAVIS_EVENT_TYPE") == "cron" {
            return .travisCron
        } else if Shell.env(name: "TRAVIS_EVENT_TYPE") == "api" {
            return .travisAPI
        } else if let tag = Shell.env(name: "TRAVIS_TAG"), !tag.isEmpty {
            return .travisPushOnTag(name: tag)
        } else if let branch = Shell.env(name: "TRAVIS_BRANCH"), !branch.isEmpty {
            return .travisPushOnBranch(branch: branch)
        } else {
            fatalError("Cannot identify job type")
        }
    }
}

enum CIError : Error {
    case invalidExitCode(statusCode: Int32, errorOutput: String?)
    case timeout
    case logicalError(message: String)
}

class Shell {
    static func executeAndPrint(_ command: String, timeout: Double = 10, allowFailure: Bool = false) throws {
        print("$ \(command)")
        let output = try executeShell(commandPath: "/bin/bash" , arguments:["-c", command], timeout: timeout, allowFailure: allowFailure) {
            print($0, separator: "", terminator: "")
        }
        if let error = output?.error {
            print(error)
        }
    }

    static func execute(_ command: String, timeout: Double = 10, allowFailure: Bool = false) throws -> (output: String?, error: String?)? {
        return try executeShell(commandPath: "/bin/bash" , arguments:["-c", command], timeout: timeout, allowFailure: allowFailure)
    }

    static func bash(commandName: String,
                     arguments: [String] = [],
                     timeout: Double = 10,
                     allowFailure: Bool = false) throws -> (output: String?, error: String?)? {
        guard let execution = try? executeShell(commandPath: "/bin/bash" ,
                                                arguments:[ "-l", "-c", "/usr/bin/which \(commandName)" ],
                                                timeout: 1),
            var whichPathForCommand = execution?.output else { return nil }
        
        whichPathForCommand = whichPathForCommand.trimmingCharacters(in: NSCharacterSet.whitespacesAndNewlines)
        return try executeShell(commandPath: whichPathForCommand, arguments: arguments, timeout: timeout, allowFailure: allowFailure)
    }

    static func executeShell(commandPath: String,
                             arguments: [String] = [],
                             timeout: Double = 10,
                             allowFailure: Bool = false,
                             stream: @escaping (String) -> Void = { _ in }) throws -> (output: String?, error: String?)? {
        let task = Process()
        task.launchPath = commandPath
        task.arguments = arguments

        let pipeForOutput = Pipe()
        task.standardOutput = pipeForOutput

        let pipeForError = Pipe()
        task.standardError = pipeForError
        task.launch()

        let fileHandle = pipeForOutput.fileHandleForReading
        fileHandle.waitForDataInBackgroundAndNotify()

        var outputData = Data()

        func process(data: Data) {
            outputData.append(data)
            if let output = String(data: data, encoding: .utf8) {
                stream(output)
            }
        }

        NotificationCenter.default.addObserver(forName: Notification.Name.NSFileHandleDataAvailable, object: fileHandle, queue: nil) { notification in
            if let fh = notification.object as? FileHandle {
                process(data: fh.availableData)
                fh.waitForDataInBackgroundAndNotify()
            }
        }
        
        var shouldTimeout = false
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if task.isRunning {
                shouldTimeout = true
                task.terminate()
            }
        }
        
        task.waitUntilExit()
        
        process(data: fileHandle.readDataToEndOfFile())
        
        if shouldTimeout {
            throw CIError.timeout
        }

        let output = String(data: outputData, encoding: .utf8)

        let errorData = pipeForError.fileHandleForReading.readDataToEndOfFile()
        let error = String(data: errorData, encoding: .utf8)

        let exitCode = task.terminationStatus
        if exitCode > 0 && !allowFailure {
            throw CIError.invalidExitCode(statusCode: exitCode, errorOutput: error)
        }

        return (output, error)
    }
    
    static func env(name: String) -> String? {
        return ProcessInfo.processInfo.environment[name]
    }
    
    static func args() -> [String] {
        return ProcessInfo.processInfo.arguments
    }
    
    static func nextArg(_ arg: String) -> String? {
        if let index = Shell.args().index(of: arg), Shell.args().count > index + 1 {
            return Shell.args()[index.advanced(by: 1)]
        }
        return nil
    }
}

Eval.main()
