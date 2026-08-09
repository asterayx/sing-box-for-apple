import Foundation
import Libbox

public enum ConfigurationValidator {
    public static func check(_ content: String) throws {
        var checkError: NSError?
        LibboxCheckConfig(content, &checkError)
        if let checkError {
            throw checkError
        }
    }
}
