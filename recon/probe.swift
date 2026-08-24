import Foundation
import ObjectiveC.runtime

setvbuf(stdout, nil, _IONBF, 0)
func cstr(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }

let path = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
guard let handle = dlopen(path, RTLD_LAZY) else { print("dlopen failed"); exit(1) }

func methodTable(_ cls: AnyClass) -> [String: String] {
    var count: UInt32 = 0
    var out: [String: String] = [:]
    guard let list = class_copyMethodList(cls, &count) else { return out }
    defer { free(list) }
    for i in 0..<Int(count) {
        out[NSStringFromSelector(method_getName(list[i]))] = cstr(method_getTypeEncoding(list[i]))
    }
    return out
}

func dump(_ name: String) {
    print("================ \(name) ================")
    guard let cls = NSClassFromString(name) else { print("  !! not found\n"); return }
    var chain: [String] = []; var c: AnyClass? = cls
    while let cc = c { chain.append(NSStringFromClass(cc)); c = class_getSuperclass(cc) }
    print("  chain: \(chain.joined(separator: " -> "))")
    let inst = methodTable(cls)
    print("  -- instance methods (\(inst.count)) --")
    for k in inst.keys.sorted() { print("    \(k)   [\(inst[k]!)]") }
    if let meta: AnyClass = object_getClass(cls) {
        let m = methodTable(meta)
        print("  -- class methods (\(m.count)) --")
        for k in m.keys.sorted() { print("    \(k)   [\(m[k]!)]") }
    }
    var pc: UInt32 = 0
    if let pl = class_copyPropertyList(cls, &pc) {
        print("  -- properties (\(pc)) --")
        for i in 0..<Int(pc) { print("    \(cstr(property_getName(pl[i])))   [\(cstr(property_getAttributes(pl[i])))]") }
        free(pl)
    }
    var ic: UInt32 = 0
    if let il = class_copyIvarList(cls, &ic) {
        print("  -- ivars (\(ic)) --")
        for i in 0..<Int(ic) { print("    \(cstr(ivar_getName(il[i])))   [\(cstr(ivar_getTypeEncoding(il[i])))]") }
        free(il)
    }
    print("")
}

print("================ classes in SidecarCore image ================")
var ccount: UInt32 = 0
if let names = objc_copyClassNamesForImage(path, &ccount) {
    var found: [String] = []
    for i in 0..<Int(ccount) { found.append(String(cString: names[i])) }
    found.sorted().forEach { print("  \($0)") }
    free(UnsafeMutableRawPointer(names))
} else {
    print("  (image not separately loaded — likely in dyld shared cache)")
}
print("")

dump("SidecarDevice")
dump("SidecarDisplay")

// ---- live inspection, object-returning selectors only ----
print("================ live manager ================")
guard let mgrCls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { exit(1) }
let mgr = mgrCls.perform(Selector(("sharedManager"))).takeUnretainedValue() as AnyObject
print("  sharedManager: \(mgr)")

// isSupported returns BOOL (B) — call through a typed function pointer, not perform.
typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool
let supSel = Selector(("isSupported"))
if let m = class_getClassMethod(mgrCls, supSel) {
    let imp = unsafeBitCast(method_getImplementation(m), to: BoolIMP.self)
    print("  +isSupported: \(imp(mgrCls, supSel))")
}

func objValue(_ target: AnyObject, _ selName: String) -> Any? {
    let sel = Selector((selName))
    guard target.responds(to: sel) else { print("  \(selName): (no such selector)"); return nil }
    guard let m = class_getInstanceMethod(type(of: target), sel),
          cstr(method_getTypeEncoding(m)).hasPrefix("@") else {
        print("  \(selName): (non-object return, skipped)"); return nil
    }
    let v = target.perform(sel)?.takeUnretainedValue()
    print("  \(selName): \(String(describing: v))")
    return v
}

let devices = objValue(mgr, "devices") as? [NSObject] ?? []
_ = objValue(mgr, "connectedDevices")
_ = objValue(mgr, "recentDevices")

print("\n  device count: \(devices.count)")
for d in devices {
    print("  ---- \(NSStringFromClass(type(of: d)))")
    for s in ["name", "identifier", "uuid", "modelIdentifier", "deviceType", "state", "isConnected", "connected", "displayID", "transport"] {
        _ = objValue(d, s)
    }
    print("  description: \(d)")
}
if let cds = mgr.perform(Selector(("connectedDevices")))?.takeUnretainedValue() as? [NSObject] {
    print("\n  connectedDevices count: \(cds.count)")
    for d in cds { _ = objValue(d, "name") }
}
