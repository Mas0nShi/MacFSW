import Foundation
import MacFSWCore

public final class MacFSWSystemExtensionMain: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let authorizer: XPCConnectionAuthorizer
    private let machServiceName: String

    public init(
        machServiceName: String = MacFSWXPCDefaults.serviceName,
        authorizer: XPCConnectionAuthorizer = XPCConnectionAuthorizer()
    ) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.authorizer = authorizer
        self.machServiceName = machServiceName
        super.init()
        self.listener.delegate = self
    }

    public func run() {
        NSLog("MacFSW Endpoint Extension starting XPC listener: %@", machServiceName)
        listener.resume()
        RunLoop.current.run()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        switch authorizer.authorize(connection) {
        case .success:
            break
        case .failure(let error):
            NSLog(
                "MacFSW rejected XPC connection from pid %d: %@",
                connection.processIdentifier,
                error.localizedDescription
            )
            connection.invalidate()
            return false
        }

        let service = MacFSWEndpointCaptureService()
        connection.exportedInterface = MacFSWXPCInterfaces.captureServiceInterface()
        connection.exportedObject = service
        connection.invalidationHandler = {
            _ = service
        }
        connection.resume()
        return true
    }
}
