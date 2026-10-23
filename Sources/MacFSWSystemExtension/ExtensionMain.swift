import Foundation
import MacFSWCore

public final class MacFSWSystemExtensionMain: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let machServiceName: String

    public init(
        machServiceName: String = MacFSWXPCDefaults.serviceName,
        clientPolicy: XPCClientPolicy = XPCClientPolicy()
    ) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.machServiceName = machServiceName
        super.init()
        // The system invalidates any connection whose peer fails the
        // requirement, checked against the peer's audit token.
        listener.setConnectionCodeSigningRequirement(clientPolicy.requirement)
        listener.delegate = self
    }

    public func run() {
        NSLog("MacFSW Endpoint Extension starting XPC listener: %@", machServiceName)
        listener.resume()
        RunLoop.current.run()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
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
