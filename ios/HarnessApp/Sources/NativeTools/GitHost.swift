import Foundation
import JavaScriptCore

/// Runs the read-only native git (`DshNativeGit`, the plan500 web modules) in a private
/// JavaScriptCore context over `NativePathSpace`. It never reaches a write API of the project: the
/// only writes it can make are the scratch index and object directory the snapshot plugin names.
public final class NativeGitHost {
    let paths: NativePathSpace
    let context: JSContext
    let queue = DispatchQueue(label: "native-tools.git")
    /// Directories git must not search above (the Worker's view of `GIT_CEILING_DIRECTORIES`).
    public let ceiling: String

    /// `scripts` are the module sources in load order: objects, match, xdiff, git.
    public init(paths: NativePathSpace, scripts: [(name: String, source: String)], ceiling: String) throws {
        self.paths = paths
        self.ceiling = ceiling
        guard let context = JSContext() else { throw ToolError("ENOEXEC", "no JavaScript context") }
        self.context = context
        let call: @convention(block) (String, JSValue, JSValue, JSValue) -> JSValue = { [paths] operation, a, b, c in
            let context = JSContext.current()!
            do { return JSValue(object: ["value": try Self.perform(paths, operation, a, b, c, context)], in: context) }
            catch let error as ToolError { return JSValue(object: ["code": error.code, "message": error.detail], in: context) }
            catch { return JSValue(object: ["code": "EIO", "message": String(describing: error)], in: context) }
        }
        context.setObject(call, forKeyedSubscript: "__dshPath" as NSString)
        for (name, source) in [("text-codec", Self.textCodec), ("fs", Self.fsGlue)] + scripts {
            context.evaluateScript(source, withSourceURL: URL(string: "native-git:///" + name))
            if let exception = context.exception {
                throw ToolError("ENOEXEC", "\(name): \(exception)")
            }
        }
        guard context.objectForKeyedSubscript("DshNativeGit")?.isObject == true else { throw ToolError("ENOEXEC", "DshNativeGit missing") }
    }

    public func run(_ argv: [String], cwd: String, env: [String: String], stdin: Data = Data()) -> ProcessOutput {
        queue.sync {
            var environment = env
            environment["GIT_CEILING_DIRECTORIES"] = ceiling
            let request = JSValue(newObjectIn: context)!
            request.setValue(argv, forProperty: "argv")
            request.setValue(cwd, forProperty: "cwd")
            request.setValue(environment, forProperty: "env")
            request.setValue(Self.makeBytes(stdin, in: context), forProperty: "stdin")
            context.exception = nil
            let result = context.objectForKeyedSubscript("DshNativeGit").invokeMethod(
                "run", withArguments: [request, context.objectForKeyedSubscript("DshNativeGitFs")!])
            if let exception = context.exception {
                context.exception = nil
                return ProcessOutput(exitCode: 128, stderr: Data("fatal: native git: host: \(exception)\n".utf8))
            }
            guard let result, let stdout = result.forProperty("stdout").flatMap(Self.bytes) else {
                return ProcessOutput(exitCode: 128, stderr: Data("fatal: native git: host: no result\n".utf8))
            }
            return ProcessOutput(exitCode: result.forProperty("exitCode").toInt32(), stdout: stdout,
                                 stderr: Data((result.forProperty("stderr").toString() ?? "").utf8))
        }
    }

    // MARK: Bridge

    static func perform(_ paths: NativePathSpace, _ operation: String, _ a: JSValue, _ b: JSValue, _ c: JSValue,
                        _ context: JSContext) throws -> Any {
        let path = a.toString() ?? ""
        switch operation {
        case "lstat": return try paths.lstat(path).dictionary
        case "realpath": return try paths.realpath(path)
        case "readlink": return try paths.readlink(path)
        case "readdir": return try paths.readdir(path).map(\.name)
        case "readFile": return makeBytes(try paths.readFile(path), in: context)
        case "read":
            return makeBytes(try paths.read(path, offset: Int(b.toDouble()), length: max(0, Int(c.toDouble()))), in: context)
        case "writeFile":
            guard let data = bytes(b) else { throw ToolError("EINVAL", "data is not a Uint8Array") }
            try paths.writeFile(path, data, exclusive: c.toBool()); return NSNull()
        case "mkdir": try paths.mkdir(path, recursive: b.toBool()); return NSNull()
        case "rename": try paths.rename(path, to: b.toString() ?? ""); return NSNull()
        case "unlink": try paths.unlink(path); return NSNull()
        default: throw ToolError("ENOSYS", operation)
        }
    }

    static func makeBytes(_ data: Data, in context: JSContext) -> JSValue {
        let ref = context.jsGlobalContextRef
        let array = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, data.count, nil)!
        if !data.isEmpty, let pointer = JSObjectGetTypedArrayBytesPtr(ref, array, nil) {
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        return JSValue(jsValueRef: array, in: context)
    }

    /// The bytes a Uint8Array views, read through its buffer so a subarray's offset is explicit.
    static func bytes(_ value: JSValue) -> Data? {
        guard let context = value.context?.jsGlobalContextRef,
              JSValueGetTypedArrayType(context, value.jsValueRef, nil) == kJSTypedArrayTypeUint8Array,
              let object = JSValueToObject(context, value.jsValueRef, nil) else { return nil }
        let length = JSObjectGetTypedArrayByteLength(context, object, nil)
        guard length > 0 else { return Data() }
        let offset = JSObjectGetTypedArrayByteOffset(context, object, nil)
        guard let buffer = JSObjectGetTypedArrayBuffer(context, object, nil),
              let base = JSObjectGetArrayBufferBytesPtr(context, buffer, nil) else { return nil }
        return Data(bytes: base + offset, count: length)
    }

    /// Node-style synchronous fs over `__dshPath`, the surface `DshNativeGit.run` uses.
    static let fsGlue = #"""
    (function (root) {
      const call = root.__dshPath;
      delete root.__dshPath;
      const fail = (code, message) => { const error = new Error(`${code}: ${message}`); error.code = code; throw error; };
      const unwrap = (r) => (r.code !== undefined ? fail(r.code, r.message) : r.value);
      const fds = new Map();
      let nextFd = 3;
      const bytes = (data) => (typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data));
      root.DshNativeGitFs = {
        lstatSync: (p) => unwrap(call("lstat", String(p))),
        realpathSync: (p) => unwrap(call("realpath", String(p))),
        readFileSync(p, options) {
          const data = unwrap(call("readFile", String(p)));
          const encoding = typeof options === "string" ? options : options && options.encoding;
          return encoding ? new TextDecoder().decode(data) : data;
        },
        readlinkSync: (p) => unwrap(call("readlink", String(p))),
        readdirSync: (p) => unwrap(call("readdir", String(p))),
        writeFileSync: (p, data, options) => unwrap(call("writeFile", String(p), bytes(data), !!(options && options.flag === "wx"))),
        mkdirSync: (p, options) => unwrap(call("mkdir", String(p), !!(options && options.recursive))),
        renameSync: (from, to) => unwrap(call("rename", String(from), String(to))),
        unlinkSync: (p) => unwrap(call("unlink", String(p))),
        openSync(p, flags) {
          if (flags !== undefined && flags !== "r") fail("EROFS", "VFS_WORKSPACE_WRITE_REFUSED");
          const real = unwrap(call("realpath", String(p)));
          unwrap(call("lstat", real));
          const fd = nextFd++;
          fds.set(fd, real);
          return fd;
        },
        readSync(fd, buffer, offset, length, position) {
          const path = fds.get(fd);
          if (path === undefined) fail("EBADF", "bad file descriptor");
          const chunk = unwrap(call("read", path, position ?? 0, length));
          buffer.set(chunk, offset);
          return chunk.length;
        },
        closeSync(fd) { fds.delete(fd); },
      };
    })(globalThis);
    """#

    /// WHATWG UTF-8 `TextEncoder`/`TextDecoder` for a bare JavaScriptCore context.
    static let textCodec = #"""
    (function (root) {
      if (typeof root.TextEncoder !== "function") {
        root.TextEncoder = class TextEncoder {
          get encoding() { return "utf-8"; }
          encode(text = "") {
            const s = String(text), out = [];
            for (let i = 0; i < s.length; i++) {
              let c = s.charCodeAt(i);
              if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
                const d = s.charCodeAt(i + 1);
                if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
              }
              if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
              if (c < 0x80) out.push(c);
              else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
              else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
              else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            }
            return new Uint8Array(out);
          }
        };
      }
      if (typeof root.TextDecoder !== "function") {
        root.TextDecoder = class TextDecoder {
          constructor(label = "utf-8", options = {}) {
            if (!/^utf-?8$/i.test(String(label))) throw new RangeError(`unsupported encoding ${label}`);
            this.fatal = !!options.fatal;
            this.ignoreBOM = !!options.ignoreBOM;
          }
          get encoding() { return "utf-8"; }
          decode(input) {
            const bytes = input === undefined ? new Uint8Array(0)
              : input instanceof Uint8Array ? input
              : ArrayBuffer.isView(input) ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
              : new Uint8Array(input);
            const points = [];
            let point = 0, needed = 0, seen = 0, lower = 0x80, upper = 0xbf;
            const bad = () => { if (this.fatal) throw new TypeError("The encoded data was not valid."); points.push(0xfffd); };
            for (let i = 0; i < bytes.length; i++) {
              const b = bytes[i];
              if (needed === 0) {
                if (b <= 0x7f) points.push(b);
                else if (b >= 0xc2 && b <= 0xdf) { needed = 1; point = b & 0x1f; }
                else if (b >= 0xe0 && b <= 0xef) { if (b === 0xe0) lower = 0xa0; if (b === 0xed) upper = 0x9f; needed = 2; point = b & 0xf; }
                else if (b >= 0xf0 && b <= 0xf4) { if (b === 0xf0) lower = 0x90; if (b === 0xf4) upper = 0x8f; needed = 3; point = b & 7; }
                else bad();
                continue;
              }
              if (b < lower || b > upper) {
                point = needed = seen = 0; lower = 0x80; upper = 0xbf;
                bad(); i--; continue;
              }
              lower = 0x80; upper = 0xbf;
              point = (point << 6) | (b & 0x3f);
              if (++seen === needed) { points.push(point); point = needed = seen = 0; }
            }
            if (needed !== 0) bad();
            let start = 0;
            if (!this.ignoreBOM && points[0] === 0xfeff) start = 1;
            let out = "";
            for (let i = start; i < points.length; i += 0x4000) out += String.fromCodePoint.apply(null, points.slice(i, Math.min(i + 0x4000, points.length)));
            return out;
          }
        };
      }
    })(globalThis);
    """#
}
