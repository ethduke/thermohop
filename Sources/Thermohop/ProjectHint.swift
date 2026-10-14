import Foundation
import Darwin

// Inspect only kernel CWD metadata. Full paths remain local to this function;
// callers receive one sanitized folder name, never arguments or file contents.
func processProjectName(_ pid: Int32, homeDirectory: String) -> String? {
    var info = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                      Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size else {
        return nil
    }
    let pathCapacity = MemoryLayout.size(ofValue: info.pvi_cdir.vip_path)
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
            guard let path = String(validatingCString: $0) else { return nil }
            return projectNameHint(path, homeDirectory: homeDirectory)
        }
    }
}

func projectNameHint(_ directory: String, homeDirectory: String) -> String? {
    guard directory.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: directory).standardizedFileURL
    let path = url.path
    let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL
    let components = url.pathComponents.filter { $0 != "/" }
    guard !components.isEmpty, path != home.path else { return nil }
    // Shared/system locations are not evidence of a project, and user/volume
    // root names can be personal identifiers rather than project names.
    if ["Users", "home", "Volumes"].contains(components[0]) && components.count <= 2 { return nil }
    let systemRoots = ["/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc"]
    if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return nil }
    if components.contains(where: { $0.lowercased().hasSuffix(".app") || $0.lowercased().hasSuffix(".framework") }) { return nil }
    let homeContainers = ["Documents", "Desktop", "Downloads", "Applications", "Library", "Pictures", "Movies", "Music", "Public"]
    if homeContainers.contains(where: { home.appendingPathComponent($0).path == path }) { return nil }
    let name = safeProcessLabel(url.lastPathComponent)
    let generic = ["unknown process", "tmp", "var", "private", "resources", "contents", "node_modules", ".git", ".build", ".local", ".config", ".cache"]
    guard !generic.contains(name.lowercased()), name.count <= 128 else { return nil }
    return name
}
