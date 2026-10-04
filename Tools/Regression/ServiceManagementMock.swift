import Foundation

// Test-only module. Regression builds import this instead of Apple's framework,
// so no test can register/unregister a real login item.
public final class SMAppService {
    public enum Status { case notRegistered, enabled, requiresApproval, notFound }
    public enum MockError: Error { case requestedFailure }
    public static let mainApp = SMAppService()
    public var status: Status = .notRegistered
    public var registerCalls = 0
    public var unregisterCalls = 0
    public var failRegister = false
    public var failUnregister = false

    public func reset(_ status: Status) {
        self.status = status
        registerCalls = 0
        unregisterCalls = 0
        failRegister = false
        failUnregister = false
    }
    public func register() throws {
        registerCalls += 1
        if failRegister { throw MockError.requestedFailure }
        status = .enabled
    }
    public func unregister() throws {
        unregisterCalls += 1
        if failUnregister { throw MockError.requestedFailure }
        status = .notRegistered
    }
}
