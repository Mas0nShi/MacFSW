import Foundation
import MacFSWSystemExtension

let serviceName = Bundle.main.object(forInfoDictionaryKey: "NSEndpointSecurityMachServiceName") as? String
if let serviceName, !serviceName.isEmpty {
    MacFSWSystemExtensionMain(machServiceName: serviceName).run()
} else {
    MacFSWSystemExtensionMain().run()
}
