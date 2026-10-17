import Darwin
import Foundation

@main
struct PeerCloseDriver {
    static func main() {
        if CommandLine.arguments[1] == "cancelled" {
            let io = LocalAPIIO(deadline: .now.advanced(by: .seconds(1)), cancelled: { true })
            do {
                _ = try io.read(-1, count: 4)
                print("unexpected_success")
            } catch let error as LocalAPIError {
                print(error.rawValue)
            } catch {
                print("unexpected_error: \(error)")
            }
            return
        }
        do {
            let response = try LocalAPIClient.call(
                LocalAPIRequest(profile: CommandLine.arguments[1], operation: .capabilities)
            )
            print(response.error?.rawValue ?? "success")
        } catch let error as LocalAPIError {
            print(error.rawValue)
        } catch {
            print("unexpected_error: \(error)")
        }
    }
}
