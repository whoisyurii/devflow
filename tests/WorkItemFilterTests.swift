import Foundation

@main
enum WorkItemFilterTests {
    static func main() {
        func matches(_ status: String = "", _ search: String = "") -> Bool {
            WorkItemFilter.matches(id: "1234", title: "Fix café upload spinner", state: "In Review", status: status, search: search)
        }
        precondition(matches())
        precondition(matches("In Review")) // Custom process states work without a hardcoded list.
        precondition(!matches("New"))
        precondition(matches("", "UPLOAD café"))
        precondition(matches("", "cafe"))
        precondition(matches("", " #1234  spinner "))
        precondition(!matches("", "#123"))
        precondition(!matches("New", "#1234"))
        precondition(!matches("In Review", "upload missing"))
        precondition(matches("In Review", "1234"))
        print("Personal work-item status and search: 10 cases passed")
    }
}
