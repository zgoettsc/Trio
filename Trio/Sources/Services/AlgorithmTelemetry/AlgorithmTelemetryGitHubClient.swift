import Foundation

/// Minimal GitHub API client for the telemetry feature. Talks to the REST v3 API.
///
/// What it does:
/// - `initializeBranchIfMissing` — creates an orphan `telemetry` branch (no shared
///   history with main) on first run, with a single README so the branch exists.
/// - `pushFiles` — commits multiple files atomically via the Git Database API
///   (one commit per push, regardless of how many files changed).
/// - `deleteFiles` — removes paths in a single commit, used by the cleanup pass.
///
/// All requests use a Personal Access Token retrieved from the Keychain at call time.
/// The client itself does NOT cache the token — that's the manager's job.
enum AlgorithmTelemetryGitHubError: Error, LocalizedError {
    case missingToken
    case invalidResponse(status: Int, body: String)
    case decodingFailed(String)
    case networkFailure(Error)
    case branchAlreadyExists

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Telemetry GitHub token missing or invalid."
        case let .invalidResponse(status, body): return "GitHub returned HTTP \(status): \(body)"
        case let .decodingFailed(reason): return "GitHub response decode failed: \(reason)"
        case let .networkFailure(err): return "Network error: \(err.localizedDescription)"
        case .branchAlreadyExists: return "Branch already exists."
        }
    }
}

final class AlgorithmTelemetryGitHubClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.github.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Creates `branch` as an orphan (no parent commits) if it doesn't exist. Idempotent.
    /// Initial commit contains README.md (orientation) and ANALYSIS_METHODS.md (the
    /// runbook for what to do with the data) so the branch is immediately
    /// self-documenting.
    func initializeBranchIfMissing(repo: String, branch: String, token: String) async throws {
        if try await branchExists(repo: repo, branch: branch, token: token) { return }

        // 1) One blob per doc
        let readmeSHA = try await createBlob(
            repo: repo,
            content: AlgorithmTelemetryDocs.readme,
            token: token
        )
        let methodsSHA = try await createBlob(
            repo: repo,
            content: AlgorithmTelemetryDocs.analysisMethods,
            token: token
        )

        // 2) Tree containing both docs
        let treeSHA = try await createTree(
            repo: repo,
            entries: [
                TreeEntry(path: "README.md", mode: "100644", type: "blob", sha: readmeSHA),
                TreeEntry(path: "ANALYSIS_METHODS.md", mode: "100644", type: "blob", sha: methodsSHA)
            ],
            baseTree: nil,
            token: token
        )

        // 3) Root commit with NO parents (orphan)
        let commitSHA = try await createCommit(
            repo: repo,
            message: "Initialize telemetry branch",
            tree: treeSHA,
            parents: [],
            token: token
        )

        // 4) Create the ref pointing at our new commit
        try await createRef(repo: repo, ref: "refs/heads/\(branch)", sha: commitSHA, token: token)
    }

    /// Atomic multi-file commit. Each entry is (repo-relative-path, file-bytes).
    /// Returns the new commit SHA on success.
    @discardableResult
    func pushFiles(
        repo: String,
        branch: String,
        files: [(path: String, contents: Data)],
        message: String,
        token: String
    ) async throws -> String {
        guard !files.isEmpty else { return "" }

        // 1) Get current branch HEAD
        let headSHA = try await getRefSHA(repo: repo, branch: branch, token: token)
        // 2) Get its tree SHA
        let headCommit = try await getCommit(repo: repo, sha: headSHA, token: token)
        let baseTreeSHA = headCommit.treeSHA

        // 3) Create one blob per file
        var entries: [TreeEntry] = []
        for file in files {
            // Push as utf-8 text so JSONL is browsable in the GitHub UI.
            let text = String(data: file.contents, encoding: .utf8) ?? ""
            let blobSHA = try await createBlob(repo: repo, content: text, token: token)
            entries.append(TreeEntry(path: file.path, mode: "100644", type: "blob", sha: blobSHA))
        }

        // 4) Build a new tree based on the current one
        let newTreeSHA = try await createTree(repo: repo, entries: entries, baseTree: baseTreeSHA, token: token)
        // 5) Commit with HEAD as parent
        let commitSHA = try await createCommit(
            repo: repo,
            message: message,
            tree: newTreeSHA,
            parents: [headSHA],
            token: token
        )
        // 6) Move ref forward
        try await updateRef(repo: repo, branch: branch, sha: commitSHA, token: token)
        return commitSHA
    }

    /// Delete multiple paths in a single commit. Used by Phase-3 cleanup.
    @discardableResult
    func deleteFiles(
        repo: String,
        branch: String,
        paths: [String],
        message: String,
        token: String
    ) async throws -> String {
        guard !paths.isEmpty else { return "" }

        let headSHA = try await getRefSHA(repo: repo, branch: branch, token: token)
        let headCommit = try await getCommit(repo: repo, sha: headSHA, token: token)

        // Setting sha to nil in a tree entry tells GitHub to delete the path.
        let entries = paths.map {
            TreeEntry(path: $0, mode: "100644", type: "blob", sha: nil)
        }
        let newTreeSHA = try await createTree(
            repo: repo,
            entries: entries,
            baseTree: headCommit.treeSHA,
            token: token
        )
        let commitSHA = try await createCommit(
            repo: repo,
            message: message,
            tree: newTreeSHA,
            parents: [headSHA],
            token: token
        )
        try await updateRef(repo: repo, branch: branch, sha: commitSHA, token: token)
        return commitSHA
    }

    /// List all file paths in the branch. Used by cleanup to find old `telemetry/YYYY-MM/DD/`
    /// directories to delete.
    func listAllPaths(repo: String, branch: String, token: String) async throws -> [String] {
        let headSHA = try await getRefSHA(repo: repo, branch: branch, token: token)
        // Recursive tree listing
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/trees/\(headSHA)?recursive=1")
        let data = try await get(url: url, token: token)
        struct TreeListResponse: Decodable {
            struct Entry: Decodable {
                let path: String
                let type: String
            }
            let tree: [Entry]
        }
        let response = try JSONDecoder().decode(TreeListResponse.self, from: data)
        return response.tree.filter { $0.type == "blob" }.map { $0.path }
    }

    // MARK: - Low-level helpers

    private func branchExists(repo: String, branch: String, token: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/ref/heads/\(branch)")
        do {
            _ = try await get(url: url, token: token)
            return true
        } catch AlgorithmTelemetryGitHubError.invalidResponse(let status, _) where status == 404 {
            return false
        }
    }

    private struct TreeEntry: Encodable {
        let path: String
        let mode: String
        let type: String
        let sha: String?
    }

    private struct CommitInfo {
        let sha: String
        let treeSHA: String
    }

    private func createBlob(repo: String, content: String, token: String) async throws -> String {
        struct Body: Encodable { let content: String; let encoding = "utf-8" }
        struct Resp: Decodable { let sha: String }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/blobs")
        let body = try JSONEncoder().encode(Body(content: content))
        let data = try await post(url: url, body: body, token: token)
        return try decode(Resp.self, from: data).sha
    }

    private func createTree(
        repo: String,
        entries: [TreeEntry],
        baseTree: String?,
        token: String
    ) async throws -> String {
        struct Body: Encodable {
            let tree: [TreeEntry]
            let base_tree: String?
        }
        struct Resp: Decodable { let sha: String }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/trees")
        let body = try JSONEncoder().encode(Body(tree: entries, base_tree: baseTree))
        let data = try await post(url: url, body: body, token: token)
        return try decode(Resp.self, from: data).sha
    }

    private func createCommit(
        repo: String,
        message: String,
        tree: String,
        parents: [String],
        token: String
    ) async throws -> String {
        struct Body: Encodable {
            let message: String
            let tree: String
            let parents: [String]
        }
        struct Resp: Decodable { let sha: String }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/commits")
        let body = try JSONEncoder().encode(Body(message: message, tree: tree, parents: parents))
        let data = try await post(url: url, body: body, token: token)
        return try decode(Resp.self, from: data).sha
    }

    private func createRef(repo: String, ref: String, sha: String, token: String) async throws {
        struct Body: Encodable { let ref: String; let sha: String }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/refs")
        let body = try JSONEncoder().encode(Body(ref: ref, sha: sha))
        _ = try await post(url: url, body: body, token: token)
    }

    private func updateRef(repo: String, branch: String, sha: String, token: String) async throws {
        struct Body: Encodable { let sha: String; let force: Bool }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/refs/heads/\(branch)")
        let body = try JSONEncoder().encode(Body(sha: sha, force: false))
        _ = try await patch(url: url, body: body, token: token)
    }

    private func getRefSHA(repo: String, branch: String, token: String) async throws -> String {
        struct RefResp: Decodable {
            struct Object: Decodable { let sha: String }
            let object: Object
        }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/ref/heads/\(branch)")
        let data = try await get(url: url, token: token)
        return try decode(RefResp.self, from: data).object.sha
    }

    private func getCommit(repo: String, sha: String, token: String) async throws -> CommitInfo {
        struct CommitResp: Decodable {
            struct Tree: Decodable { let sha: String }
            let sha: String
            let tree: Tree
        }
        let url = baseURL.appendingPathComponent("/repos/\(repo)/git/commits/\(sha)")
        let data = try await get(url: url, token: token)
        let resp = try decode(CommitResp.self, from: data)
        return CommitInfo(sha: resp.sha, treeSHA: resp.tree.sha)
    }

    // MARK: - HTTP

    private func get(url: URL, token: String) async throws -> Data {
        try await request(url: url, method: "GET", body: nil, token: token)
    }

    private func post(url: URL, body: Data, token: String) async throws -> Data {
        try await request(url: url, method: "POST", body: body, token: token)
    }

    private func patch(url: URL, body: Data, token: String) async throws -> Data {
        try await request(url: url, method: "PATCH", body: body, token: token)
    }

    private func request(url: URL, method: String, body: Data?, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Trio-Telemetry", forHTTPHeaderField: "User-Agent")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AlgorithmTelemetryGitHubError.invalidResponse(status: 0, body: "no HTTPURLResponse")
            }
            if !(200 ... 299).contains(http.statusCode) {
                let text = String(data: data, encoding: .utf8) ?? "<binary>"
                throw AlgorithmTelemetryGitHubError.invalidResponse(status: http.statusCode, body: text)
            }
            return data
        } catch let err as AlgorithmTelemetryGitHubError {
            throw err
        } catch {
            throw AlgorithmTelemetryGitHubError.networkFailure(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AlgorithmTelemetryGitHubError.decodingFailed(String(describing: error))
        }
    }
}
