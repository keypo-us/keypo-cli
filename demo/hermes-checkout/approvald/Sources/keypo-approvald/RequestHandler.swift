import Foundation

class RequestHandler {
    private var stagedRequest: StagedRequest?
    private let checkoutScript: String
    private let vaultUser: String?
    private let expirySeconds: TimeInterval = 300 // 5 minutes

    init(checkoutScript: String, vaultUser: String?) {
        self.checkoutScript = checkoutScript
        self.vaultUser = vaultUser
    }

    func handle(_ message: IncomingMessage) -> ResponseMessage {
        log("← action=\(message.action) request_id=\(message.request_id ?? "(auto)")")
        switch message.action {
        case "request":
            return handleRequest(message)
        case "confirm":
            return handleConfirm(message)
        case "cancel":
            return handleCancel(message)
        default:
            log("  ✘ unknown action")
            return ResponseMessage(
                status: "error",
                request_id: message.request_id,
                error: "unknown action: \(message.action)"
            )
        }
    }

    // MARK: - Request (Stage)

    private func handleRequest(_ message: IncomingMessage) -> ResponseMessage {
        // Check for already staged request
        if let existing = stagedRequest {
            // Check if expired
            if Date().timeIntervalSince(existing.stagedAt) >= expirySeconds {
                log("  ⏰ previous request \(existing.requestId) expired, clearing")
                stagedRequest = nil
            } else {
                log("  ✘ already staged: \(existing.requestId)")
                return ResponseMessage(
                    status: "error",
                    request_id: message.request_id,
                    error: "another request is already staged (id: \(existing.requestId))"
                )
            }
        }

        // Validate required fields
        guard let vaultLabel = message.vault_label, !vaultLabel.isEmpty else {
            return ResponseMessage(
                status: "error",
                request_id: message.request_id,
                error: "missing required field: vault_label"
            )
        }
        guard let bioReason = message.bio_reason, !bioReason.isEmpty else {
            return ResponseMessage(
                status: "error",
                request_id: message.request_id,
                error: "missing required field: bio_reason"
            )
        }
        guard let manifest = message.manifest else {
            return ResponseMessage(
                status: "error",
                request_id: message.request_id,
                error: "missing required field: manifest"
            )
        }

        let requestId = message.request_id ?? UUID().uuidString

        stagedRequest = StagedRequest(
            requestId: requestId,
            vaultLabel: vaultLabel,
            bioReason: bioReason,
            manifest: manifest,
            stagedAt: Date()
        )

        log("  ✓ staged \(requestId) bio_reason=\"\(bioReason)\"")
        return ResponseMessage(
            status: "staged",
            request_id: requestId
        )
    }

    // MARK: - Confirm (Execute)

    private func handleConfirm(_ message: IncomingMessage) -> ResponseMessage {
        guard let requestId = message.request_id else {
            return ResponseMessage(
                status: "error",
                request_id: nil,
                error: "missing required field: request_id"
            )
        }

        guard let staged = stagedRequest, staged.requestId == requestId else {
            let stagedId = stagedRequest?.requestId ?? "(none)"
            log("  ✘ no match: confirm=\(requestId) staged=\(stagedId)")
            return ResponseMessage(
                status: "error",
                request_id: requestId,
                error: "no staged request for this request_id (staged: \(stagedId))"
            )
        }

        // Check expiry
        if Date().timeIntervalSince(staged.stagedAt) >= expirySeconds {
            stagedRequest = nil
            log("  ✘ request expired")
            return ResponseMessage(
                status: "error",
                request_id: requestId,
                error: "request expired"
            )
        }

        // Clear staged request before execution
        stagedRequest = nil

        log("  → executing checkout for \(requestId)...")
        let result = executeCheckout(staged)
        log("  ← checkout result: status=\(result.status) exit_code=\(result.exit_code ?? -1)")
        return result
    }

    // MARK: - Cancel

    private func handleCancel(_ message: IncomingMessage) -> ResponseMessage {
        guard let requestId = message.request_id else {
            return ResponseMessage(
                status: "error",
                request_id: nil,
                error: "missing required field: request_id"
            )
        }

        guard let staged = stagedRequest, staged.requestId == requestId else {
            return ResponseMessage(
                status: "error",
                request_id: requestId,
                error: "no staged request for this request_id"
            )
        }

        stagedRequest = nil
        log("  ✓ cancelled \(requestId)")

        return ResponseMessage(
            status: "cancelled",
            request_id: requestId
        )
    }

    // MARK: - Execution

    private func executeCheckout(_ staged: StagedRequest) -> ResponseMessage {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        if let user = vaultUser {
            // Production mode: use sudo wrapper
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [
                "-u", user,
                "/usr/local/libexec/keypo/checkout-wrapper.sh",
                staged.bioReason
            ]
        } else {
            // Local dev mode: call keypo-signer directly
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "keypo-signer", "vault", "exec",
                "--allow", "*",
                "--reason", staged.bioReason,
                "--", "node", checkoutScript
            ]
        }

        log("  cmd: \(process.arguments?.joined(separator: " ") ?? "(nil)")")

        // Serialize manifest to JSON and write to stdin
        let manifestData: Data
        do {
            manifestData = try staged.manifest.toJSONData()
        } catch {
            return ResponseMessage(
                status: "error",
                request_id: staged.requestId,
                error: "failed to serialize manifest: \(error)"
            )
        }

        log("  manifest: \(String(data: manifestData, encoding: .utf8) ?? "(nil)")")

        do {
            try process.run()
        } catch {
            log("  ✘ failed to start: \(error)")
            return ResponseMessage(
                status: "error",
                request_id: staged.requestId,
                error: "failed to start process: \(error)"
            )
        }

        log("  pid: \(process.processIdentifier) — waiting for biometric + checkout...")

        // Write manifest to child stdin and close
        stdinPipe.fileHandleForWriting.write(manifestData)
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exitCode = Int(process.terminationStatus)

        log("  exit_code=\(exitCode)")
        if !stderrStr.isEmpty {
            // Log stderr but redact potential card data
            let safeStderr = stderrStr.count > 500 ? String(stderrStr.prefix(500)) + "..." : stderrStr
            log("  stderr: \(safeStderr)")
        }
        if !stdoutStr.isEmpty {
            log("  stdout: \(stdoutStr)")
        }

        // Check for biometric cancellation
        if stderrStr.contains("biometric authentication cancelled") || stderrStr.contains("authentication cancelled") {
            return ResponseMessage(
                status: "error",
                request_id: staged.requestId,
                exit_code: exitCode,
                stdout: stdoutStr.isEmpty ? nil : stdoutStr,
                stderr: stderrStr.isEmpty ? nil : stderrStr,
                error: "biometric authentication cancelled"
            )
        }

        if stderrStr.contains("biometric authentication failed") {
            return ResponseMessage(
                status: "error",
                request_id: staged.requestId,
                exit_code: exitCode,
                stdout: stdoutStr.isEmpty ? nil : stdoutStr,
                stderr: stderrStr.isEmpty ? nil : stderrStr,
                error: "biometric authentication failed"
            )
        }

        if exitCode == 0 {
            return ResponseMessage(
                status: "completed",
                request_id: staged.requestId,
                exit_code: exitCode,
                stdout: stdoutStr.isEmpty ? nil : stdoutStr,
                stderr: stderrStr.isEmpty ? nil : stderrStr
            )
        } else {
            return ResponseMessage(
                status: "error",
                request_id: staged.requestId,
                exit_code: exitCode,
                stdout: stdoutStr.isEmpty ? nil : stdoutStr,
                stderr: stderrStr.isEmpty ? nil : stderrStr,
                error: "checkout failed"
            )
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
    }
}
